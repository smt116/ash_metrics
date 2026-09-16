defmodule AshMetrics do
  @moduledoc """
  Declarative business metrics for Ash resources.

  `AshMetrics` is an `Ash.Resource` extension that adds a `metrics do` block in
  which counters and distributions are declared next to the action they describe
  and validated at compile time. Those declarations compile to
  `Telemetry.Metrics` definitions rather than to a new emit/aggregate/export
  pipeline, so the host application's existing reporter is what actually ships
  them to a backend.

      defmodule MyApp.Mailings.TemplatedDelivery do
        use Ash.Resource,
          domain: MyApp.Mailings,
          extensions: [AshMetrics]

        metrics do
          name :templated_delivery

          counter :delivery,
            outcomes: [:queued, :sent, :bounced, :delivered, :error],
            tags: [:provider, :template]
        end
      end

  Counters and distributions are emitted by hand, at the moment the outcome
  becomes known:

      AshMetrics.increment(MyApp.Mailings.TemplatedDelivery, :delivery,
        outcome: :sent,
        tags: %{provider: "ses", template: "welcome_v2"},
        metadata: changeset.context
      )

      AshMetrics.observe(MyApp.Mailings.TemplatedDelivery, :send_latency, 142,
        tags: %{provider: "ses"},
        metadata: changeset.context
      )

  What the host application consumes is `metrics/0`: the declarations of every
  resource, compiled to `Telemetry.Metrics` definitions, ready to be spliced
  into whatever reporter it already runs.

  See `AshMetrics.Dsl` for the section definition and `AshMetrics.Info` for
  introspection.
  """

  use Spark.Dsl.Extension,
    sections: [AshMetrics.Dsl.metrics()],
    verifiers: [
      AshMetrics.Verifiers.VerifyPrefix,
      AshMetrics.Verifiers.VerifyMetrics
    ]

  alias Ash.Domain.Info, as: DomainInfo
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Info
  alias AshMetrics.NameBuilder
  alias AshMetrics.TagExtractor

  @typedoc "Tag keys and values attached to an emission."
  @type tags :: %{optional(atom()) => term()}

  @doc """
  The `:telemetry` event name of a metric.

  The resource module is part of the event name, so two resources declaring the
  same metric name never share an event, whatever the configured name builder
  makes of them.

      AshMetrics.event_name(MyApp.Mailings.TemplatedDelivery, :delivery)
      #=> [:ash_metrics, MyApp.Mailings.TemplatedDelivery, :delivery]
  """
  @spec event_name(module(), atom()) :: [atom()]
  def event_name(resource, metric), do: [:ash_metrics, resource, metric]

  @doc """
  Emits one count of the counter `metric` on `resource`.

  Everything is checked before the event is executed, and anything wrong raises
  `ArgumentError` rather than emitting a metric nobody asked for:

  * `metric` must be a declared `counter` on `resource`
  * `outcome` must be one of that counter's declared outcomes
  * every key of `tags` must be one of that counter's declared tags

  ## Options

  * `:outcome` — required. The outcome the event ended in.
  * `:tags` — a map of call-site tags, defaulting to `%{}`.
  * `:metadata` — a map passed to the configured `AshMetrics.TagExtractor`,
    defaulting to `%{}`. Anything shaped like Ash event metadata will do; a
    changeset's context is the usual thing to pass.

  Extracted tags are merged under the explicit ones, so a call site can always
  override what the extractor derived.

  ## Example

      AshMetrics.increment(MyApp.Mailings.TemplatedDelivery, :delivery,
        outcome: :bounced,
        tags: %{provider: "ses"},
        metadata: %{tenant: "acme"}
      )
  """
  @spec increment(module(), atom(), keyword()) :: :ok
  def increment(resource, metric, opts) do
    counter = counter!(resource, metric)
    outcome = outcome!(resource, counter, opts)
    tags = Map.put(tags(resource, counter, opts), Config.outcome_tag(), outcome)

    :telemetry.execute(event_name(resource, metric), %{count: 1}, tags)
  end

  @spec counter!(module(), atom()) :: Counter.t()
  defp counter!(resource, metric) do
    case Info.metric!(resource, metric) do
      %Counter{} = counter ->
        counter

      %Distribution{} ->
        raise ArgumentError,
              "#{inspect(metric)} on #{inspect(resource)} is a distribution, not a " <>
                "counter. Use `observe/4` to record a distribution."

      %Gauge{} ->
        raise ArgumentError, gauge_message(resource, metric, "counter")
    end
  end

  @doc """
  Records `value` for the distribution `metric` on `resource`.

  As with `increment/3`, everything is checked before the event is executed and
  anything wrong raises `ArgumentError`: `metric` must be a declared
  `distribution` on `resource`, `value` must be a number, and every key of
  `tags` must be one of that distribution's declared tags.

  The value is recorded in whatever unit the declaration says. A declaration
  with a conversion unit such as `{:native, :millisecond}` converts when the
  metric definition is compiled, not here, so a call site can pass a raw
  monotonic-time difference.

  ## Options

  * `:tags` — a map of call-site tags, defaulting to `%{}`.
  * `:metadata` — a map passed to the configured `AshMetrics.TagExtractor`,
    defaulting to `%{}`.

  ## Example

      AshMetrics.observe(MyApp.Mailings.TemplatedDelivery, :send_latency, 142,
        tags: %{provider: "ses"},
        metadata: %{tenant: "acme"}
      )
  """
  @spec observe(module(), atom(), number(), keyword()) :: :ok
  def observe(resource, metric, value, opts \\ [])

  def observe(resource, metric, value, opts) when is_number(value) do
    distribution = distribution!(resource, metric)

    :telemetry.execute(
      event_name(resource, metric),
      %{value: value},
      tags(resource, distribution, opts)
    )
  end

  def observe(resource, metric, value, _opts) do
    raise ArgumentError,
          "observe/4 records a number, got: #{inspect(value)}. Distribution " <>
            "#{inspect(metric)} on #{inspect(resource)} cannot record anything else."
  end

  @spec distribution!(module(), atom()) :: Distribution.t()
  defp distribution!(resource, metric) do
    case Info.metric!(resource, metric) do
      %Distribution{} = distribution ->
        distribution

      %Counter{} ->
        raise ArgumentError,
              "#{inspect(metric)} on #{inspect(resource)} is a counter, not a " <>
                "distribution. Use `increment/3` to emit a counter."

      %Gauge{} ->
        raise ArgumentError, gauge_message(resource, metric, "distribution")
    end
  end

  @spec gauge_message(module(), atom(), String.t()) :: String.t()
  defp gauge_message(resource, metric, kind) do
    "#{inspect(metric)} on #{inspect(resource)} is a gauge, not a #{kind}. A " <>
      "gauge is polled by AshMetrics itself and has no call site."
  end

  @spec outcome!(module(), Counter.t(), keyword()) :: atom()
  defp outcome!(resource, counter, opts) do
    case Keyword.fetch(opts, :outcome) do
      {:ok, outcome} -> declared_outcome!(resource, counter, outcome)
      :error -> raise ArgumentError, missing_outcome_message(resource, counter)
    end
  end

  @spec declared_outcome!(module(), Counter.t(), term()) :: atom()
  defp declared_outcome!(resource, counter, outcome) do
    if outcome in counter.outcomes do
      outcome
    else
      raise ArgumentError,
            "#{inspect(outcome)} is not a declared outcome of counter " <>
              "#{inspect(counter.name)} on #{inspect(resource)}. Declared outcomes: " <>
              list(counter.outcomes)
    end
  end

  @spec missing_outcome_message(module(), Counter.t()) :: String.t()
  defp missing_outcome_message(resource, counter) do
    "increment/3 requires an `outcome:` option. Counter #{inspect(counter.name)} " <>
      "on #{inspect(resource)} declares the outcomes: #{list(counter.outcomes)}"
  end

  @spec tags(module(), Counter.t() | Distribution.t(), keyword()) :: tags()
  defp tags(resource, metric, opts) do
    explicit = Keyword.get(opts, :tags, %{})
    declared_tags!(resource, metric, explicit)

    opts
    |> Keyword.get(:metadata, %{})
    |> TagExtractor.extract()
    |> Map.merge(explicit)
  end

  @spec declared_tags!(module(), Counter.t() | Distribution.t(), tags()) :: :ok
  defp declared_tags!(resource, metric, explicit) do
    case Enum.reject(Map.keys(explicit), &(&1 in metric.tags)) do
      [] ->
        :ok

      [key | _rest] ->
        raise ArgumentError,
              "#{inspect(key)} is not a declared tag of #{kind(metric)} " <>
                "#{inspect(metric.name)} on #{inspect(resource)}. Declared tags: " <>
                list(metric.tags)
    end
  end

  @doc """
  The `Telemetry.Metrics` definitions of every resource that declares metrics.

  The resources are found through the Ash domains of the configured
  `AshMetrics.Config.otp_app!/0`, so a resource that is not reachable from a
  configured domain is not included. Pass an explicit list to `metrics_for/1`
  if that is not what you want.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    Config.otp_app!()
    |> Ash.Info.domains()
    |> Enum.flat_map(&DomainInfo.resources/1)
    |> metrics_for()
  end

  @doc """
  The `Telemetry.Metrics` definitions of the given resources.

  Named `metrics_for/1` rather than `metrics/1` because the `metrics` section
  builder this module generates for the DSL already occupies `metrics/1`.

  Resources that do not use the `AshMetrics` extension are skipped rather than
  rejected, so a list of every resource in an application can be passed without
  filtering it first.

  A counter becomes a `Telemetry.Metrics.Counter` named `<metric>.count` and a
  distribution a `Telemetry.Metrics.Distribution` named `<metric>.duration`,
  where the part before the suffix is what the configured
  `AshMetrics.NameBuilder` returns. Each definition's tags are the declared tags
  plus the keys the configured `AshMetrics.TagExtractor` supplies, plus the
  outcome tag for a counter, which is exactly the set of keys an emission can
  carry.

  Finally, the configured backend gets a chance to rewrite the list through
  `c:AshMetrics.Backend.transform_metrics/2`, if it implements that optional
  callback.

  Splice the result into a reporter:

      children = [
        {Telemetry.Metrics.ConsoleReporter, metrics: AshMetrics.metrics()}
      ]
  """
  @spec metrics_for([module()]) :: [Telemetry.Metrics.t()]
  def metrics_for(resources) do
    extractor_keys = Config.tag_extractor().tag_keys()

    resources
    |> Enum.filter(&declares_metrics?/1)
    |> Enum.flat_map(fn resource ->
      resource
      |> Info.metrics()
      |> Enum.reject(&match?(%Gauge{}, &1))
      |> Enum.map(&definition(resource, &1, extractor_keys))
    end)
    |> transform()
  end

  @spec declares_metrics?(module()) :: boolean()
  defp declares_metrics?(resource), do: __MODULE__ in Spark.extensions(resource)

  @spec definition(module(), Counter.t() | Distribution.t(), [atom()]) ::
          Telemetry.Metrics.t()
  defp definition(resource, %Counter{} = counter, extractor_keys) do
    Telemetry.Metrics.counter(
      NameBuilder.build(resource, counter.name) <> ".count",
      event_name: event_name(resource, counter.name),
      measurement: :count,
      tags: [Config.outcome_tag() | counter.tags] ++ extractor_keys,
      description: counter.description
    )
  end

  defp definition(resource, %Distribution{} = distribution, extractor_keys) do
    Telemetry.Metrics.distribution(
      NameBuilder.build(resource, distribution.name) <> ".duration",
      [
        event_name: event_name(resource, distribution.name),
        measurement: :value,
        unit: distribution.unit,
        tags: distribution.tags ++ extractor_keys,
        description: distribution.description
      ] ++ reporter_options(distribution)
    )
  end

  @spec reporter_options(Distribution.t()) :: keyword()
  defp reporter_options(%Distribution{buckets: nil}), do: []

  defp reporter_options(%Distribution{buckets: buckets}),
    do: [reporter_options: [buckets: buckets]]

  @spec transform([Telemetry.Metrics.t()]) :: [Telemetry.Metrics.t()]
  defp transform(metrics) do
    backend = Config.backend()

    if Code.ensure_loaded?(backend) and function_exported?(backend, :transform_metrics, 2) do
      backend.transform_metrics(metrics, [])
    else
      metrics
    end
  end

  @spec kind(Counter.t() | Distribution.t()) :: String.t()
  defp kind(%Counter{}), do: "counter"
  defp kind(%Distribution{}), do: "distribution"

  @spec list([atom()]) :: String.t()
  defp list([]), do: "none"
  defp list(values), do: Enum.map_join(values, ", ", &inspect/1)
end
