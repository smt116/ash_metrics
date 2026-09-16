defmodule AshMetrics.Dsl.Gauge do
  @moduledoc """
  A gauge declared in a resource's `metrics` block.

  A gauge answers "how many right now?". Unlike a counter or a distribution it
  is never emitted from a call site: the package polls it, computes one value
  per group with the declared strategy, and emits each of them as a
  `Telemetry.Metrics.LastValue`.

  `group_by` is a list of attributes of the resource, and its values become the
  tags of the emission, so a gauge with `group_by: [:status]` publishes one
  timeseries per status rather than one metric name per status.
  """

  defstruct [
    :name,
    :filter,
    :description,
    group_by: [],
    strategy: :count,
    period: 60_000,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          filter: term(),
          group_by: [atom()],
          strategy: :count | module(),
          period: pos_integer(),
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }
end
