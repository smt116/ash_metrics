defmodule AshMetrics do
  @moduledoc """
  Declarative business metrics for Ash resources.

  `AshMetrics` is an `Ash.Resource` extension that adds a `metrics do` block in
  which counters, gauges and distributions are declared next to the action they
  describe and validated at compile time. Those declarations compile to
  `Telemetry.Metrics` definitions; the host application's existing reporter
  ships them to a backend.

      defmodule MyApp.Mailings.TemplatedDelivery do
        use Ash.Resource,
          domain: MyApp.Mailings,
          extensions: [AshMetrics]

        metrics do
          name :templated_delivery

          counter :delivery,
            tags: [:provider, :template, status: [:queued, :sent, :bounced, :delivered, :error]]

          gauge :backlog,
            filter: expr(status in [:pending, :processing]),
            group_by: [:status]
        end
      end

  Counters and distributions are emitted by hand, at the moment the outcome
  becomes known:

      AshMetrics.increment(MyApp.Mailings.TemplatedDelivery, :delivery,
        tags: %{status: :sent, provider: "ses", template: "welcome_v2"},
        metadata: changeset.context
      )

      AshMetrics.observe(MyApp.Mailings.TemplatedDelivery, :send_latency, 142,
        tags: %{provider: "ses"},
        metadata: changeset.context
      )

  When the fact is written by an Ash action, `increment_on_change/2` and
  `observe_elapsed/2` declare a `change` that emits it from that action.

  A gauge is never emitted from a call site: `AshMetrics.Poller` polls it every
  `period` and emits one value per group.

  A host application consumes `metrics/0`, the declarations of every resource
  compiled to `Telemetry.Metrics` definitions, ready to be spliced into
  whatever reporter it already runs, and `child_specs/1`, which starts the
  configured backend and the poller.

  A declaration that fails one of this extension's verifiers is reported by the
  compiler as a warning pointing at the declaration, not as a hard error;
  compile with `--warnings-as-errors` to turn it into one.

  See `AshMetrics.Dsl` for the section definition and `AshMetrics.Info` for
  introspection.
  """

  use Spark.Dsl.Extension,
    sections: [AshMetrics.Dsl.metrics()],
    transformers: [
      AshMetrics.Poller.AshOban.Transformer
    ],
    verifiers: [
      AshMetrics.Verifiers.VerifyPrefix,
      AshMetrics.Verifiers.VerifyMetrics,
      AshMetrics.Verifiers.VerifyTenantSource,
      AshMetrics.Verifiers.VerifyChanges
    ]

  alias Ash.Domain.Info, as: DomainInfo
  alias AshMetrics.Backend
  alias AshMetrics.Changes.IncrementOnChange
  alias AshMetrics.Changes.IncrementOnWrite
  alias AshMetrics.Changes.ObserveElapsed
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Info
  alias AshMetrics.NameBuilder
  alias AshMetrics.Poller
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

  Everything is checked before the event is executed; anything wrong raises
  `ArgumentError`:

  * `metric` must be a declared `counter` on `resource`
  * `tags` must be a map or a keyword list
  * every key of `tags` must be one of that counter's declared tags
  * every closed tag of that counter must be present, with one of its declared
    values

  ## Options

  * `:tags` — the call-site tags, as a map or a keyword list, defaulting to
    `%{}`.
  * `:metadata` — a map passed to the configured `AshMetrics.TagExtractor`,
    defaulting to `%{}`. Anything shaped like Ash event metadata will do; a
    changeset's context is the usual thing to pass.

  Extracted tags are merged under the explicit ones, so a call site can always
  override what the extractor derived.

  ## Example

      AshMetrics.increment(MyApp.Mailings.TemplatedDelivery, :delivery,
        tags: %{status: :bounced, provider: "ses"},
        metadata: %{tenant: "acme"}
      )
  """
  @spec increment(module(), atom(), keyword()) :: :ok
  def increment(resource, metric, opts \\ []) do
    counter = counter!(resource, metric)

    :telemetry.execute(
      event_name(resource, metric),
      %{count: 1},
      tags(resource, counter, opts)
    )
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
  `distribution` on `resource`, `value` must be a number, `tags` must be a map
  or a keyword list, every key of `tags` must be one of that distribution's
  declared tags, and every closed tag must be present with one of its declared
  values.

  The value is recorded in whatever unit the declaration says. A declaration
  with a conversion unit such as `{:native, :millisecond}` converts when the
  metric definition is compiled, not here, so a call site can pass a raw
  monotonic-time difference.

  ## Options

  * `:tags` — the call-site tags, as a map or a keyword list, defaulting to
    `%{}`.
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

  @doc """
  Declares a `change` that counts `attribute` taking a new value into the
  counter `metric`.

  Use it on the action that writes the attribute:

      update :update_status do
        accept [:status]
        require_atomic? false

        change AshMetrics.increment_on_change(:delivery, :status)
      end

  The counter must declare `attribute` as one of its `tags`, open or closed;
  the emitted tag is what the action wrote. A verifier rejects the resource
  otherwise.

  `increment_on_write/2` counts every write of the attribute instead, and runs
  atomically.

  `AshMetrics.Changes.IncrementOnChange` documents what is emitted, when, and
  why the action needs `require_atomic? false`.
  """
  @spec increment_on_change(atom(), atom()) :: {module(), keyword()}
  def increment_on_change(metric, attribute) do
    {IncrementOnChange, counter: metric, attribute: attribute}
  end

  @doc """
  Declares a `change` that counts every write of `attribute` into the counter
  `metric`.

  Use it on the action that writes the attribute:

      update :update_status do
        accept [:status]

        change AshMetrics.increment_on_write(:delivery, :status)
      end

  It counts every `{:ok, record}`, whatever the attribute held before: a
  create counts, and an update writing the same value again counts again. It
  runs atomically, so the action can keep `require_atomic? true`.

  The counter must declare `attribute` as one of its `tags`, open or closed;
  the emitted tag is what the action wrote. A verifier rejects the resource
  otherwise.

  `AshMetrics.Changes.IncrementOnWrite` documents what is emitted and when.
  """
  @spec increment_on_write(atom(), atom()) :: {module(), keyword()}
  def increment_on_write(metric, attribute) do
    {IncrementOnWrite, counter: metric, attribute: attribute}
  end

  @doc """
  Declares a `change` that records the time between two timestamps of the
  written record into the distribution `metric`.

  Use it on the action that writes the later timestamp, with `where:` when
  only one transition should be measured:

      update :update_status do
        accept [:status, :delivered_at]
        require_atomic? false

        change AshMetrics.observe_elapsed(:delivery_time,
                 from: :inserted_at,
                 to: :delivered_at
               ),
               where: [attribute_equals(:status, :delivered)]
      end

  ## Options

  * `:from` — the attribute holding the earlier timestamp. Required.
  * `:to` — the attribute holding the later timestamp, or `:now` for the
    moment the hook runs. Defaults to `:now`.

  Both attributes must be datetime attributes and the distribution's `unit`
  must be a time unit; a verifier rejects the resource otherwise.

  `AshMetrics.Changes.ObserveElapsed` documents what is observed, when, and
  why the action needs `require_atomic? false`.
  """
  @spec observe_elapsed(atom(), keyword()) :: {module(), keyword()}
  def observe_elapsed(metric, opts) do
    {ObserveElapsed,
     opts
     |> Keyword.take([:from, :to])
     |> Keyword.put_new(:to, :now)
     |> Keyword.put(:distribution, metric)}
  end

  @doc false
  @spec tags!(term()) :: tags()
  def tags!(tags) when is_map(tags), do: tags

  def tags!(tags) when is_list(tags) do
    if Keyword.keyword?(tags) do
      Map.new(tags)
    else
      raise ArgumentError, tags_message(tags)
    end
  end

  def tags!(tags), do: raise(ArgumentError, tags_message(tags))

  @spec tags_message(term()) :: String.t()
  defp tags_message(tags) do
    "`tags:` takes a map or a keyword list, got: #{inspect(tags)}"
  end

  @spec tags(module(), Counter.t() | Distribution.t(), keyword()) :: tags()
  defp tags(resource, metric, opts) do
    explicit = opts |> Keyword.get(:tags, %{}) |> tags!()
    declared_tags!(resource, metric, explicit)
    declared_values!(resource, metric, explicit)

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

  @spec declared_values!(module(), Counter.t() | Distribution.t(), tags()) :: :ok
  defp declared_values!(resource, metric, explicit) do
    Enum.each(metric.tags, fn key ->
      case Map.fetch(metric.tag_values, key) do
        {:ok, values} ->
          declared_value!(resource, metric, key, values, Map.fetch(explicit, key))

        :error ->
          :ok
      end
    end)
  end

  @spec declared_value!(
          module(),
          Counter.t() | Distribution.t(),
          atom(),
          [atom()],
          {:ok, term()} | :error
        ) :: :ok
  defp declared_value!(resource, metric, key, values, :error) do
    raise ArgumentError,
          "#{inspect(key)} is a required tag of #{kind(metric)} " <>
            "#{inspect(metric.name)} on #{inspect(resource)}. Declared values: " <>
            list(values)
  end

  defp declared_value!(resource, metric, key, values, {:ok, value}) do
    if value in values do
      :ok
    else
      raise ArgumentError,
            "#{inspect(value)} is not a declared value of the tag #{inspect(key)} " <>
              "of #{kind(metric)} #{inspect(metric.name)} on #{inspect(resource)}. " <>
              "Declared values: " <> list(values)
    end
  end

  @doc """
  Everything AshMetrics needs running, for a supervision tree.

  The configured `AshMetrics.Backend`'s children come first, followed by
  whatever the configured `AshMetrics.Poller` needs to poll the declared
  gauges. Splice the result into a supervision tree after the repository; see
  the README for a worked example.

  `opts` are passed to both. An application that declares no gauges and runs
  the default backend still gets the poller's process, which sits idle.

  A `:poll` option overrides `AshMetrics.Config.poll?/0`, and is not passed
  on; `false` leaves out every poller's children. A backend that reports the
  gauges itself leaves them out whatever the option says; see
  `c:AshMetrics.Backend.polls_gauges?/0`.

  `AshMetrics.Supervisor` supervises exactly this, for an application that
  would rather add one child than splice a list.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    {poll?, opts} = Keyword.pop(opts, :poll, Config.poll?())

    Backend.child_specs(opts) ++
      poller_child_specs(poll? and not Backend.polls_gauges?(), opts)
  end

  @spec poller_child_specs(boolean(), keyword()) :: [Supervisor.child_spec()]
  defp poller_child_specs(true, opts), do: Poller.child_specs(opts)
  defp poller_child_specs(false, _opts), do: []

  @doc """
  The `Telemetry.Metrics` definitions of every resource that declares metrics.

  The resources are found through the Ash domains of the configured
  `AshMetrics.Config.otp_app!/0`, so a resource that is not reachable from a
  configured domain is not included. Pass an explicit list to `metrics_for/1`
  if that is not what you want.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics, do: metrics_for(resources())

  @doc """
  Every resource of the configured application's Ash domains that declares
  metrics.
  """
  @spec resources() :: [module()]
  def resources do
    Config.otp_app!()
    |> Ash.Info.domains()
    |> Enum.flat_map(&DomainInfo.resources/1)
    |> Enum.filter(&declares_metrics?/1)
  end

  @doc """
  The `Telemetry.Metrics` definitions of the given resources.

  Resources that do not use the `AshMetrics` extension are skipped, so a list
  of every resource in an application can be passed without filtering it
  first.

  A counter becomes a `Telemetry.Metrics.Counter` named `<metric>.count`, a
  distribution a `Telemetry.Metrics.Distribution` named `<metric>.duration`,
  and a gauge a `Telemetry.Metrics.LastValue` named `<metric>.gauge`, where the
  part before the suffix is what the configured `AshMetrics.NameBuilder`
  returns. A counter's and a distribution's tags are the declared tag keys plus
  the keys the configured `AshMetrics.TagExtractor` supplies, which is exactly
  the set of keys an emission can carry.

  A gauge's tags are its `group_by` attributes, plus `tenant` when the resource
  is multitenant under either of Ash's strategies. The tag extractor's keys are
  not added: a gauge has no call-site metadata to read them from.

  The configured backend may rewrite the result through
  `c:AshMetrics.Backend.transform_metrics/2`.
  """
  @spec metrics_for([module()]) :: [Telemetry.Metrics.t()]
  def metrics_for(resources) do
    extractor_keys = Config.tag_extractor().tag_keys()

    resources
    |> Enum.filter(&declares_metrics?/1)
    |> Enum.flat_map(fn resource ->
      Enum.map(Info.metrics(resource), &definition(resource, &1, extractor_keys))
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
      tags: counter.tags ++ extractor_keys,
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

  defp definition(resource, %Gauge{} = gauge, _extractor_keys) do
    Telemetry.Metrics.last_value(
      NameBuilder.build(resource, gauge.name) <> ".gauge",
      event_name: event_name(resource, gauge.name),
      measurement: :value,
      tags: gauge.group_by ++ tenant_tag(resource),
      description: gauge.description
    )
  end

  @spec tenant_tag(module()) :: [atom()]
  defp tenant_tag(resource) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      nil -> []
      _strategy -> [:tenant]
    end
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
