defmodule AshMetrics.Dsl.Counter do
  @moduledoc """
  A counter declared in a resource's `metrics` block.

  A counter answers "how many events, and how fast?". It is emitted manually
  with AshMetrics.increment/3 at the moment a business outcome becomes known,
  and it compiles to a single `Telemetry.Metrics.Counter` carrying an `outcome`
  tag whose permitted values are exactly the declared `outcomes`.
  """

  defstruct [:name, :outcomes, :description, tags: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          outcomes: [atom()],
          tags: [atom()],
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }
end
