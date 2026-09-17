defmodule AshMetrics.Dsl.Counter do
  @moduledoc """
  A counter declared in a resource's `metrics` block.

  A counter answers "how many events, and how fast?". It is emitted manually
  with `AshMetrics.increment/3` at the moment a business outcome becomes known,
  and it compiles to a single `Telemetry.Metrics.Counter`.

  `tags` holds every declared tag key in declaration order and `tag_values` the
  declared values of the closed ones; see `AshMetrics.Dsl.Tags`. An `outcomes`
  declaration is folded into both under the configured
  `AshMetrics.Config.outcome_tag/0`.
  """

  alias AshMetrics.Config
  alias AshMetrics.Dsl.Tags

  defstruct [
    :name,
    :outcomes,
    :description,
    tags: [],
    tag_values: %{},
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          outcomes: [atom()] | nil,
          tags: [atom()],
          tag_values: %{optional(atom()) => [atom()]},
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }

  @doc false
  @spec transform(t()) :: {:ok, t()}
  def transform(%__MODULE__{outcomes: nil} = counter), do: Tags.transform(counter)

  def transform(%__MODULE__{outcomes: outcomes} = counter) do
    outcome_tag = Config.outcome_tag()
    {keys, values} = Tags.normalize(counter.tags)

    {:ok,
     %{
       counter
       | tags: [outcome_tag | keys],
         tag_values: Map.put(values, outcome_tag, outcomes)
     }}
  end
end
