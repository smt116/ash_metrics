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

    `outcomes` is the closed set of permitted values for the `outcome` tag. It is
    a tag rather than a name segment, so a counter with five outcomes is one
    metric name with five tag values, not five metric names. Emitting an outcome
    that is not declared raises.

    `tags` is an allowlist. Only the keys listed here may be passed as call-site
    tags, which is what keeps unbounded values out of the metric.
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

  @metrics %Spark.Dsl.Section{
    name: :metrics,
    describe: """
    Declares the business metrics of a resource.

    Declarations here compile to `Telemetry.Metrics` definitions, returned by
    `AshMetrics.metrics/0`, which the host application's reporter ships to its
    own backend.
    """,
    examples: [
      """
      metrics do
        name :templated_delivery

        counter :delivery,
          outcomes: [:queued, :sent, :bounced, :delivered, :error],
          tags: [:provider, :template]
      end
      """
    ],
    schema: [
      name: [
        type: :atom,
        required: false,
        doc: "Overrides the resource short name used in metric names."
      ]
    ],
    entities: [@counter]
  }

  @doc """
  The `metrics` section, as consumed by `use Spark.Dsl.Extension`.
  """
  @spec metrics() :: Spark.Dsl.Section.t()
  def metrics, do: @metrics
end
