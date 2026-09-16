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

  It is a module rather than a function capture so that the thing a resource
  points at is inspectable and testable on its own, as with
  `AshMetrics.NameBuilder` and `AshMetrics.TagExtractor`.

  ## The contract

  `c:compute/3` returns one entry per group, `{tags, value}`, where `tags` maps
  each of the gauge's `group_by` attribute names to that group's value. A gauge
  that groups by nothing returns exactly one entry, `{%{}, value}`. A gauge
  that groups by something returns no entry at all for a group with no rows,
  which is the honest answer: nothing in the table says the group exists.
  `AshMetrics.Gauge.Runner` is what turns a group that has vanished since the
  last poll into a zero.

  Every entry is emitted as one measurement with the tags it carries, so the
  cardinality of the result is the cardinality of the metric. Returning one
  entry per row of a large table publishes one timeseries per row.
  """

  alias AshMetrics.Dsl.Gauge

  @typedoc "One group of a gauge: the tags identifying it, and its value."
  @type group :: {AshMetrics.tags(), number()}

  @doc """
  Computes the current value of `gauge` on `resource`, one entry per group.

  ## Options

  * `:tenant` — the tenant to run the query as, or `nil`. Set for a resource
    using Ash's `:context` multitenancy strategy, where the strategy is called
    once per tenant.

  Returns `{:error, reason}` rather than raising, so that one failing gauge
  neither takes the poller down nor stops the others from being emitted.
  """
  @callback compute(resource :: module(), gauge :: Gauge.t(), opts :: keyword()) ::
              {:ok, [group()]} | {:error, term()}
end
