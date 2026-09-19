if Code.ensure_loaded?(:otel_meter) do
  defmodule AshMetrics.Backend.Otel do
    @moduledoc """
    A backend for an application that exports through OpenTelemetry with the
    `OtelTelemetryMetrics` bridge.

    The host application keeps its own `OtelTelemetryMetrics` instance and
    still splices `AshMetrics.metrics/0` into the list of metrics it hands it.

        config :ash_metrics, backend: AshMetrics.Backend.Otel

        config :ash_metrics, AshMetrics.Backend.Otel, timeout: 5_000

    ## What it changes

    * Every `Telemetry.Metrics.LastValue` is dropped from that list. The
      gauges those stood for are reported as OpenTelemetry observable gauges
      instead.
    * A `Telemetry.Metrics.Distribution` declaring `buckets` carries them on
      as the histogram's `explicit_bucket_boundaries`, under the `:otel`
      reporter option the bridge reads. `:buckets` is left in place for any
      other reporter.
    * Everything else is passed through unchanged.

    ## How a gauge is counted

    Starting the backend creates one observable gauge instrument per declared
    gauge, named as the dropped `Telemetry.Metrics.LastValue` was. Its
    callback counts the gauge through `AshMetrics.Gauge.Runner.poll/2` when
    the collector asks for a value, at most once per the gauge's `period` per
    node; a collection that arrives within that period of the last count is
    served the values that count produced.

    A count is given `timeout` milliseconds. One that overruns it is killed,
    and the values of the last count that finished are reported again, as they
    are when the count fails. Either way the failure is logged as a warning
    and the next collection counts again.

    A group that has vanished since it was last counted is reported as a zero,
    and goes on being reported as a zero until the node restarts.

    Tag values reach OpenTelemetry as attributes: an atom, a binary, a number
    or a boolean as it is, a struct not at all, and anything else inspected.

    ## Polling

    This backend reports the gauges itself, so `AshMetrics.child_specs/1`
    starts no gauge poller for it; see
    `c:AshMetrics.Backend.polls_gauges?/0`. Do not select
    `AshMetrics.Poller.AshOban` alongside it: its Oban schedules would keep
    running and emit measurements nothing reports.
    """

    @behaviour AshMetrics.Backend

    use GenServer

    require Logger

    alias AshMetrics.Config
    alias AshMetrics.Dsl.Gauge
    alias AshMetrics.Gauge.Runner
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
    @spec polls_gauges?() :: true
    def polls_gauges?, do: true

    @impl AshMetrics.Backend
    @spec transform_metrics([Telemetry.Metrics.t()], keyword()) :: [Telemetry.Metrics.t()]
    def transform_metrics(metrics, _opts) do
      metrics
      |> Enum.reject(&match?(%Telemetry.Metrics.LastValue{}, &1))
      |> Enum.map(&boundaries/1)
    end

    @doc """
    Starts the process that owns the instruments and the counts they serve.

    ## Options

    * `:gauges` — the gauges to report, as `{resource, gauge}` tuples.
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
    The current value of one gauge, for the instrument's callback.

    Called by the OpenTelemetry SDK when it collects, with `{resource,
    gauge}`. Returns one observation per group, serving the last count when it
    is younger than the gauge's `period`.
    """
    @spec observe({module(), Gauge.t()}) :: [observation()]
    def observe({resource, %Gauge{} = gauge}) do
      {counted_at, observations, known} = entry(resource, gauge)

      if fresh?(counted_at, gauge.period) do
        observations
      else
        count(resource, gauge, observations, known)
      end
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
    defp fresh?(counted_at, period), do: now() - counted_at < period

    @spec count(module(), Gauge.t(), [observation()], [attributes()]) ::
            [observation()]
    defp count(resource, %Gauge{} = gauge, observations, known) do
      case counted(resource, gauge) do
        {:ok, {:ok, groups}} -> store(resource, gauge, groups, known)
        failure -> failed(resource, gauge, failure, observations)
      end
    end

    # The caller is the SDK's collection process. A count that overruns the
    # timeout is abandoned, and nothing the count does may exit the caller.
    @spec counted(module(), Gauge.t()) :: {:ok, term()} | {:exit, term()} | nil
    defp counted(resource, %Gauge{} = gauge) do
      task = Task.async(fn -> poll(resource, gauge) end)

      Task.yield(task, Config.otel_timeout()) || Task.shutdown(task, :brutal_kill)
    end

    @spec poll(module(), Gauge.t()) :: {:ok, [Strategy.group()]} | {:error, term()}
    defp poll(resource, gauge) do
      Runner.poll(resource, gauge)
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {:error, {kind, reason}}
    end

    @spec store(module(), Gauge.t(), [Strategy.group()], [attributes()]) :: [observation()]
    defp store(resource, %Gauge{} = gauge, groups, known) do
      counted = Enum.map(groups, fn {tags, value} -> {value, attributes(tags)} end)
      observations = counted ++ vanished(counted, known)
      remembered = Enum.map(observations, fn {_value, attributes} -> attributes end)

      :ets.insert(@table, {{resource, gauge.name}, now(), observations, remembered})

      observations
    end

    @spec vanished([observation()], [attributes()]) :: [observation()]
    defp vanished(counted, known) do
      present = MapSet.new(counted, fn {_value, attributes} -> attributes end)

      known
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.map(&{0, &1})
    end

    @spec failed(module(), Gauge.t(), term(), [observation()]) :: [observation()]
    defp failed(resource, %Gauge{} = gauge, failure, observations) do
      Logger.warning(
        "AshMetrics could not count the gauge #{inspect(gauge.name)} on " <>
          "#{inspect(resource)}: #{inspect(reason(failure))}. " <>
          "#{length(observations)} observation(s) of the last count that " <>
          "finished are reported instead."
      )

      observations
    end

    @spec reason(term()) :: term()
    defp reason(nil), do: {:timeout, Config.otel_timeout()}
    defp reason({:ok, {:error, error}}), do: error
    defp reason({:exit, error}), do: {:exit, error}

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
