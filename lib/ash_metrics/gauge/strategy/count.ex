defmodule AshMetrics.Gauge.Strategy.Count do
  @moduledoc """
  Counts the rows matching a gauge exactly, one count per group.

  This is the default strategy, and the only one that needs nothing from the
  resource but its own attributes.

  ## Cost

  Ash has no `GROUP BY`. A grouped gauge is therefore one read of the distinct
  values of its `group_by` attributes, to learn which groups exist, followed by
  one `Ash.count/2` per group: `1 + groups` queries per poll, and once per
  tenant for a resource `AshMetrics.Gauge.Runner` polls per tenant. A gauge
  with no `group_by` is a single count.

  On `AshPostgres.DataLayer`, `AshMetrics.Gauge.Strategy.Postgres.Count`
  returns the same counts from one query. A resource where either is too
  expensive can declare its own `AshMetrics.Gauge.Strategy`, such as an
  estimate from the database's own statistics or a cached value.

  Every query runs with `authorize?: false`, since a poll has no actor.

  It takes no options: a gauge declaring
  `strategy: {AshMetrics.Gauge.Strategy.Count, options}` with any is rejected
  while the resource compiles.
  """

  @behaviour AshMetrics.Gauge.Strategy

  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy
  alias AshMetrics.Gauge.Strategy.PerGroup

  @impl AshMetrics.Gauge.Strategy
  @spec verify(Spark.Dsl.t(), Gauge.t()) :: :ok | {:error, String.t()}
  def verify(_dsl_state, %Gauge{strategy_opts: []}), do: :ok

  def verify(_dsl_state, %Gauge{strategy_opts: opts}),
    do: {:error, "it takes no options, and was given #{inspect(opts)}."}

  @impl AshMetrics.Gauge.Strategy
  @spec compute(module(), Gauge.t(), keyword()) :: {:ok, [Strategy.group()]} | {:error, term()}
  def compute(resource, %Gauge{} = gauge, opts),
    do: PerGroup.compute(resource, gauge, opts, &Ash.count(&1, authorize?: false))
end
