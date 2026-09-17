defmodule AshMetrics.Gauge.Strategy do
  @moduledoc """
  Computes the current value of a gauge, one value per group.

  A strategy is where the query behind a gauge lives. The default,
  `AshMetrics.Gauge.Strategy.Count`, counts rows exactly; a resource whose
  table is too large to count on every period, or whose number is cheaper to
  obtain some other way, declares its own:

      gauge :backlog,
        filter: expr(status == :pending),
        group_by: [:status],
        strategy: MyApp.Stats.Backlog

  ## The contract

  `c:compute/3` returns one entry per group, `{tags, value}`, where `tags` maps
  each of the gauge's `group_by` attribute names to that group's value. A gauge
  that groups by nothing returns exactly one entry, `{%{}, value}`. A gauge
  that groups by something returns no entry at all for a group with no rows.
  `AshMetrics.Gauge.Runner` turns a group that has vanished since the last poll
  into a zero.

  Every entry is emitted as one measurement with the tags it carries, so the
  cardinality of the result is the cardinality of the metric. Returning one
  entry per row of a large table publishes one timeseries per row.

  The gauge a strategy is handed is not always the one that was declared:
  `AshMetrics.Gauge.Runner` may append the tenant attribute to `group_by`.
  Group by what the gauge you are given says, and see that module for how each
  multitenancy strategy is polled.
  """

  alias AshMetrics.Dsl.Gauge

  @typedoc "One group of a gauge: the tags identifying it, and its value."
  @type group :: {AshMetrics.tags(), number()}

  @doc """
  Computes the current value of `gauge` on `resource`, one entry per group.

  ## Options

  * `:tenant` — the tenant to run the query as, or `nil`. Set for a resource
    that is polled once per tenant: one using Ash's `:context` multitenancy
    strategy, or its `:attribute` strategy without `global? true`.

  Return `{:error, reason}` rather than raising: one failing gauge must neither
  take the poller down nor stop the others from being emitted.
  """
  @callback compute(resource :: module(), gauge :: Gauge.t(), opts :: keyword()) ::
              {:ok, [group()]} | {:error, term()}
end
