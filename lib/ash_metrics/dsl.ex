defmodule AshMetrics.Dsl do
  @moduledoc """
  The `metrics` DSL section that `AshMetrics` adds to an Ash resource.

  This module only builds the `Spark.Dsl.Section` struct; the extension itself
  is `AshMetrics`. Read declarations back with `AshMetrics.Info` rather than by
  reaching into the DSL state directly.
  """

  @counter %Spark.Dsl.Entity{
    name: :counter,
    describe: """
    Declares a counter: how many times a business event happened, broken down by
    outcome.

    `outcomes` is the closed set of permitted values for the `outcome` tag: a
    counter with five outcomes is one metric name carrying five tag values, not
    five metric names. Emitting an outcome that is not declared raises.

    `tags` is an allowlist. Only the keys listed here may be passed as call-site
    tags.
    """,
    examples: [
      "counter :delivery, outcomes: [:sent, :bounced, :error]",
      """
      counter :delivery do
        outcomes [:queued, :sent, :bounced, :delivered, :error]
        tags [:provider, :template]
        description "Templated deliveries by outcome"
      end
      """
    ],
    target: AshMetrics.Dsl.Counter,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the counter, used as the last segment of the metric name."
      ],
      outcomes: [
        type: {:list, :atom},
        required: true,
        doc: "The permitted values of the outcome tag. Must be non-empty and free of duplicates."
      ],
      tags: [
        type: {:list, :atom},
        default: [],
        doc: "The tag keys this counter accepts at the call site, beyond the outcome tag."
      ],
      description: [
        type: :string,
        required: false,
        doc: "A human readable description, passed through to the metric definition."
      ]
    ]
  }

  @distribution %Spark.Dsl.Entity{
    name: :distribution,
    describe: """
    Declares a distribution: the spread of an observed numeric value, such as
    latency or payload size.

    Values are observed one at a time; the histogram itself is built by the
    reporter. `buckets` are reporter specific boundaries, passed through
    untouched, and `unit` may be a conversion tuple, so a call site can observe
    a native time unit without converting first.

    As with counters, `tags` is an allowlist of the keys a call site may pass.
    """,
    examples: [
      "distribution :send_latency, unit: {:native, :millisecond}",
      """
      distribution :send_latency do
        unit {:native, :millisecond}
        buckets [10, 50, 100, 250, 500, 1_000, 5_000]
        tags [:provider]
        description "Time from enqueue to provider acknowledgement"
      end
      """
    ],
    target: AshMetrics.Dsl.Distribution,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the distribution, used as the last segment of the metric name."
      ],
      unit: [
        type: {:or, [:atom, {:tuple, [:atom, :atom]}]},
        default: :unit,
        doc:
          "The unit of the observed value, or a `Telemetry.Metrics` conversion tuple such as `{:native, :millisecond}`."
      ],
      buckets: [
        type: {:list, :number},
        required: false,
        doc:
          "Histogram bucket boundaries, strictly ascending and positive. Passed to the reporter as `reporter_options[:buckets]`."
      ],
      tags: [
        type: {:list, :atom},
        default: [],
        doc: "The tag keys this distribution accepts at the call site."
      ],
      description: [
        type: :string,
        required: false,
        doc: "A human readable description, passed through to the metric definition."
      ]
    ]
  }

  @gauge %Spark.Dsl.Entity{
    name: :gauge,
    describe: """
    Declares a gauge: how many rows match a filter right now, broken down by
    the values of `group_by`.

    Nothing emits a gauge by hand. The package polls it every `period`,
    computes one value per group, and emits each one.

    `group_by` names attributes of the resource, and their values become the
    tags of the emission. One gauge with `group_by: [:status]` is one metric
    name with one timeseries per status.

    A poll costs queries. See `AshMetrics.Gauge.Strategy.Count` for what the
    default strategy costs, and `AshMetrics.Gauge.Strategy` for supplying one
    of your own.
    """,
    examples: [
      "gauge :backlog, filter: expr(status == :pending)",
      """
      gauge :backlog do
        filter expr(status in [:pending, :processing])
        group_by [:status, :provider]
        period :timer.minutes(1)
        description "Jobs waiting to be picked up"
      end
      """
    ],
    target: AshMetrics.Dsl.Gauge,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the gauge, used as the last segment of the metric name."
      ],
      filter: [
        type: :any,
        required: false,
        doc:
          "An Ash expression, built with `expr/1`, restricting what is counted. Counts every row when absent."
      ],
      group_by: [
        type: {:list, :atom},
        default: [],
        doc:
          "Attributes of the resource to break the value down by. Their values are the tags of each emission."
      ],
      strategy: [
        type: {:or, [{:literal, :count}, {:behaviour, AshMetrics.Gauge.Strategy}]},
        default: :count,
        doc:
          "`:count` for an exact count, or an `AshMetrics.Gauge.Strategy` module computing the value some other way."
      ],
      period: [
        type: :pos_integer,
        default: 60_000,
        doc:
          "How often to poll, in milliseconds. Sub-minute periods are usually wasted resolution: most collectors flush on a ten second interval, and every poll costs queries."
      ],
      description: [
        type: :string,
        required: false,
        doc: "A human readable description, passed through to the metric definition."
      ]
    ]
  }

  @metrics %Spark.Dsl.Section{
    name: :metrics,
    describe: """
    Declares the business metrics of a resource.

    Declarations here compile to `Telemetry.Metrics` definitions, returned by
    `AshMetrics.metrics/0`, which the host application's reporter ships to its
    own backend.

    `Ash.Expr` is imported into this section, so a gauge's `filter` can be
    written with `expr/1` exactly as it would be anywhere else in the resource.
    """,
    examples: [
      """
      metrics do
        name :templated_delivery

        counter :delivery,
          outcomes: [:queued, :sent, :bounced, :delivered, :error],
          tags: [:provider, :template]

        gauge :backlog,
          filter: expr(status in [:pending, :processing]),
          group_by: [:status, :provider],
          period: :timer.minutes(1)

        distribution :send_latency,
          unit: {:native, :millisecond},
          buckets: [10, 50, 100, 250, 500, 1_000, 5_000],
          tags: [:provider]
      end
      """
    ],
    imports: [Ash.Expr],
    schema: [
      name: [
        type: :atom,
        required: false,
        doc: "Overrides the resource short name used in metric names."
      ],
      poller: [
        type: {:behaviour, AshMetrics.Poller},
        required: false,
        doc:
          "Overrides the configured `AshMetrics.Poller` for this resource's gauges. Every poller of an application is asked for its children, so two resources may be polled by two different mechanisms."
      ]
    ],
    entities: [@counter, @gauge, @distribution]
  }

  @doc """
  The `metrics` section, as consumed by `use Spark.Dsl.Extension`.
  """
  @spec metrics() :: Spark.Dsl.Section.t()
  def metrics, do: @metrics
end
