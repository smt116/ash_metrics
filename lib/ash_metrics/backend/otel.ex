if Code.ensure_loaded?(:otel_meter) do
  defmodule AshMetrics.Backend.Otel do
    @moduledoc """
    A backend for an application that exports through OpenTelemetry with the
    `OtelTelemetryMetrics` bridge.

    The host application keeps its own `OtelTelemetryMetrics` instance and
    still splices `AshMetrics.metrics/0` into the list of metrics it hands it.

        config :ash_metrics, backend: AshMetrics.Backend.Otel

    ## What it changes

    * Every `Telemetry.Metrics.LastValue` is dropped from that list. The
      gauges those stood for are exported as OpenTelemetry observable gauges
      instead.
    * A `Telemetry.Metrics.Distribution` declaring `buckets` carries them on
      as the histogram's `explicit_bucket_boundaries`, under the `:otel`
      reporter option the bridge reads. `:buckets` is left in place for any
      other reporter.
    * Everything else is passed through unchanged.

    ## How a gauge is exported

    Starting the backend creates one observable gauge instrument per declared
    gauge, named as the dropped `Telemetry.Metrics.LastValue` was. Its
    callback serves the groups the configured `AshMetrics.Poller` last
    reported for that gauge on this node, for twice the gauge's `period` after
    that report. Outside that window, and before the first report, it serves
    nothing, and the SDK forgets an observable instrument whose callback
    returns nothing: this node then exports no series for that gauge in that
    collection cycle.

    A group that was reported and is absent from the next report is served as
    a zero, and goes on being served as a zero until the node restarts.

    With `AshMetrics.Poller.AshOban` one node runs each poll and only that
    node holds a value, so the cluster exports one series per gauge from one
    query per period. With `AshMetrics.Poller.GenServer` every node polls and
    exports its own series.

    Tag values reach OpenTelemetry as attributes: an atom, a binary, a number
    or a boolean as it is, a struct not at all, and anything else inspected.

    ## Starting it

    This backend has to be running before a poller reports to it;
    `AshMetrics.child_specs/1` puts it before the pollers, and
    `AshMetrics.Supervisor` starts exactly that list. A report that arrives
    while it is not running is logged as an error and dropped.
    """

    @behaviour AshMetrics.Backend

    use GenServer

    require Logger

    alias AshMetrics.Dsl.Gauge
    alias AshMetrics.Gauge.Strategy
    alias AshMetrics.NameBuilder
    alias AshMetrics.Poller

    @table __MODULE__

    @typedoc "OpenTelemetry attributes, one gauge group's tags."
    @type attributes :: %{optional(atom()) => atom() | binary() | number()}

    @typedoc "One observation of an observable gauge: its value, and its attributes."
    @type observation :: {number(), attributes()}

    @impl AshMetrics.Backend
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    @impl AshMetrics.Backend
    @spec transform_metrics([Telemetry.Metrics.t()], keyword()) :: [Telemetry.Metrics.t()]
    def transform_metrics(metrics, _opts) do
      metrics
      |> Enum.reject(&match?(%Telemetry.Metrics.LastValue{}, &1))
      |> Enum.map(&boundaries/1)
    end

    @impl AshMetrics.Backend
    @spec report_gauge(module(), Gauge.t(), [Strategy.group()]) :: :ok
    def report_gauge(resource, %Gauge{} = gauge, groups) do
      if :ets.whereis(@table) == :undefined do
        not_running(resource, gauge)
      else
        store(resource, gauge, groups)
      end
    end

    @doc """
    Starts the process that owns the instruments and the observations they
    serve.

    ## Options

    * `:gauges` — the gauges to export, as `{resource, gauge}` tuples.
      Defaults to `AshMetrics.Poller.gauges/0`.
    * `:name` — a name to register the process under.
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    end

    @impl GenServer
    @spec init(keyword()) :: {:ok, atom()}
    def init(opts) do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

      meter =
        :opentelemetry_experimental.get_meter(:opentelemetry.get_application_scope(__MODULE__))

      opts
      |> Keyword.get_lazy(:gauges, &Poller.gauges/0)
      |> Enum.each(&register(meter, &1))

      {:ok, @table}
    end

    @doc """
    The observations of one gauge, for the instrument's callback.

    Called by the OpenTelemetry SDK when it collects, with `{resource,
    gauge}`. Returns one observation per group of the last report of that
    gauge on this node, or `[]` when there has been no report or the last one
    is at least twice the gauge's `period` old.
    """
    @spec observe({module(), Gauge.t()}) :: [observation()]
    def observe({resource, %Gauge{} = gauge}) do
      {reported_at, observations, _known} = entry(resource, gauge)

      if fresh?(reported_at, gauge.period), do: observations, else: []
    end

    @spec register(:otel_meter.t(), Poller.gauge()) :: :ok
    defp register(meter, {resource, %Gauge{} = gauge}) do
      :ets.insert(@table, {{resource, gauge.name}, nil, [], []})

      :otel_meter.create_observable_gauge(
        meter,
        instrument(resource, gauge),
        &__MODULE__.observe/1,
        {resource, gauge},
        instrument_opts(gauge)
      )

      :ok
    end

    @spec instrument(module(), Gauge.t()) :: atom()
    defp instrument(resource, %Gauge{} = gauge) do
      String.to_atom(NameBuilder.build(resource, gauge.name) <> ".gauge")
    end

    # `unit` is `1`, the unit of a dimensionless count, and has to be an atom.
    @spec instrument_opts(Gauge.t()) :: map()
    defp instrument_opts(%Gauge{description: nil}), do: %{unit: :"1"}
    defp instrument_opts(%Gauge{description: text}), do: %{unit: :"1", description: text}

    @spec entry(module(), Gauge.t()) ::
            {integer() | nil, [observation()], [attributes()]}
    defp entry(resource, %Gauge{} = gauge) do
      case :ets.lookup(@table, {resource, gauge.name}) do
        [{_key, counted_at, observations, known}] -> {counted_at, observations, known}
        [] -> {nil, [], []}
      end
    end

    @spec fresh?(integer() | nil, pos_integer()) :: boolean()
    defp fresh?(nil, _period), do: false
    defp fresh?(reported_at, period), do: now() - reported_at < 2 * period

    @spec store(module(), Gauge.t(), [Strategy.group()]) :: :ok
    defp store(resource, %Gauge{} = gauge, groups) do
      {_reported_at, _observations, known} = entry(resource, gauge)

      reported = Enum.map(groups, fn {tags, value} -> {value, attributes(tags)} end)
      observations = reported ++ vanished(reported, known)
      remembered = Enum.map(observations, fn {_value, attributes} -> attributes end)

      :ets.insert(@table, {{resource, gauge.name}, now(), observations, remembered})

      :ok
    end

    @spec vanished([observation()], [attributes()]) :: [observation()]
    defp vanished(reported, known) do
      present = MapSet.new(reported, fn {_value, attributes} -> attributes end)

      known
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.map(&{0, &1})
    end

    @spec not_running(module(), Gauge.t()) :: :ok
    defp not_running(resource, %Gauge{} = gauge) do
      Logger.error(
        "AshMetrics dropped a report of the gauge #{inspect(gauge.name)} on " <>
          "#{inspect(resource)}: AshMetrics.Backend.Otel is not running, so " <>
          "there is no instrument to serve it. Add it to the supervision tree " <>
          "through AshMetrics.Supervisor, or through AshMetrics.child_specs/1, " <>
          "which puts it before the pollers."
      )
    end

    @spec attributes(AshMetrics.tags()) :: attributes()
    defp attributes(tags) do
      tags
      |> Enum.flat_map(fn {key, value} ->
        case attribute(value) do
          {:ok, attribute} -> [{key, attribute}]
          :drop -> []
        end
      end)
      |> Map.new()
    end

    @spec attribute(term()) :: {:ok, atom() | binary() | number()} | :drop
    defp attribute(value) when is_atom(value) or is_binary(value) or is_number(value),
      do: {:ok, value}

    defp attribute(value) when is_struct(value), do: :drop
    defp attribute(value), do: {:ok, inspect(value)}

    @spec boundaries(Telemetry.Metrics.t()) :: Telemetry.Metrics.t()
    defp boundaries(%Telemetry.Metrics.Distribution{} = metric) do
      case Keyword.get(metric.reporter_options, :buckets) do
        buckets when is_list(buckets) ->
          otel = Keyword.get(metric.reporter_options, :otel, %{})

          %{
            metric
            | reporter_options:
                Keyword.put(metric.reporter_options, :otel, advisory(otel, buckets))
          }

        _other ->
          metric
      end
    end

    defp boundaries(metric), do: metric

    @spec advisory(map(), [number()]) :: map()
    defp advisory(otel, buckets) do
      params =
        otel
        |> Map.get(:advisory_params, %{})
        |> Map.put(:explicit_bucket_boundaries, buckets)

      Map.put(otel, :advisory_params, params)
    end

    @spec now() :: integer()
    defp now, do: System.monotonic_time(:millisecond)
  end
else
  defmodule AshMetrics.Backend.Otel do
    @moduledoc """
    A backend for an application that exports through OpenTelemetry with the
    `OtelTelemetryMetrics` bridge.

    This is the stub compiled when `opentelemetry_api_experimental` is not
    available. Every function raises.
    """

    @behaviour AshMetrics.Backend

    @missing """
    AshMetrics.Backend.Otel needs the `opentelemetry_api_experimental` \
    package, which is not available.

    Add it to your dependencies and run `mix deps.get`:

        {:opentelemetry_api_experimental, "~> 0.6"}

    An application that does not export through OpenTelemetry should select \
    another `AshMetrics.Backend`.
    """

    @impl AshMetrics.Backend
    @spec child_spec(keyword()) :: no_return()
    def child_spec(_opts), do: raise(@missing)

    @impl AshMetrics.Backend
    @spec transform_metrics([Telemetry.Metrics.t()], keyword()) :: no_return()
    def transform_metrics(_metrics, _opts), do: raise(@missing)
  end
end
