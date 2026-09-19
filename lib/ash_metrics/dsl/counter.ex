defmodule AshMetrics.Dsl.Counter do
  @moduledoc """
  A counter declared in a resource's `metrics` block.

  A counter answers "how many events, and how fast?". It is emitted manually
  with `AshMetrics.increment/3` at the moment a business outcome becomes known,
  and it compiles to a single `Telemetry.Metrics.Counter`.

  `tags` holds every declared tag key in declaration order, `tag_values` the
  declared values of the closed ones and `tag_paths` the declared path of
  those read from the written record; see `AshMetrics.Dsl.Tags`.
  """

  defstruct [
    :name,
    :description,
    tags: [],
    tag_values: %{},
    tag_paths: %{},
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          tags: [atom()],
          tag_values: %{optional(atom()) => [atom()]},
          tag_paths: %{optional(atom()) => [atom(), ...]},
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }
end
