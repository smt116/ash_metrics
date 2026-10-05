if Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AshMetrics.Gauge.Strategy.Postgres.Count do
    @moduledoc """
    Counts the rows matching a gauge exactly, every group in one query.

    Returns what `AshMetrics.Gauge.Strategy.Count` returns on the same rows,
    from a single `GROUP BY` statement per poll, or per tenant for a resource
    `AshMetrics.Gauge.Runner` polls per tenant, in place of `1 + groups`.

        gauge :backlog,
          filter: expr(status in [:pending, :processing]),
          group_by: [:status, :provider],
          strategy: AshMetrics.Gauge.Strategy.Postgres.Count

    The statement is built by Ash from the gauge's filter, the resource's base
    filter, and the preparations and filter of its primary read action, and
    honours the tenant under either multitenancy strategy. It runs without
    authorization, on the repo `AshPostgres.DataLayer.Info.repo/2` gives for
    reads.

    On a resource whose primary read action's preparations set a limit or an
    offset, this strategy and `AshMetrics.Gauge.Strategy.Count` both read a
    truncated set of rows, and their results differ: this strategy groups the
    rows of that one read.

    A resource whose data layer is not `AshPostgres.DataLayer` is rejected
    while it compiles, and so is any option: this strategy takes none.

    Needs `ash_postgres`; see `AshMetrics.Gauge.Strategy.Postgres.Transformer`.
    """

    @behaviour AshMetrics.Gauge.Strategy

    import Ecto.Query

    alias AshMetrics.Dsl.Gauge
    alias AshMetrics.Gauge.Strategy
    alias AshMetrics.Gauge.Strategy.Postgres.Query

    @impl AshMetrics.Gauge.Strategy
    @spec verify(Spark.Dsl.t(), Gauge.t()) :: :ok | {:error, String.t()}
    def verify(dsl_state, %Gauge{strategy_opts: opts}) do
      with :ok <- Query.verify(dsl_state) do
        if opts == [],
          do: :ok,
          else: {:error, "it takes no options, and was given #{inspect(opts)}."}
      end
    end

    @impl AshMetrics.Gauge.Strategy
    @spec compute(module(), Gauge.t(), keyword()) ::
            {:ok, [Strategy.group()]} | {:error, term()}
    def compute(resource, %Gauge{} = gauge, opts) do
      with {:ok, query} <- Query.rows(resource, gauge, opts),
           do: count(resource, query, gauge.group_by)
    end

    @spec count(module(), Ecto.Query.t(), [atom()]) ::
            {:ok, [Strategy.group()]} | {:error, term()}
    defp count(resource, query, []) do
      with {:ok, count} <- Query.one(resource, select(query, [row], count())),
           do: {:ok, [{%{}, count}]}
    end

    defp count(resource, query, group_by),
      do: Query.grouped(resource, query, group_by, dynamic(count()))
  end
else
  defmodule AshMetrics.Gauge.Strategy.Postgres.Count do
    @moduledoc """
    Counts the rows matching a gauge exactly, every group in one query.

    This is the stub compiled when `ash_postgres` is not available; see
    `AshMetrics.Gauge.Strategy.Postgres.Transformer`. Computing one returns an
    error.
    """

    @behaviour AshMetrics.Gauge.Strategy

    @missing """
    AshMetrics.Gauge.Strategy.Postgres.Count needs the `ash_postgres` \
    package, which is not available. Add it to your dependencies, \
    `{:ash_postgres, "~> 2.13"}`, or choose another strategy, such as \
    AshMetrics.Gauge.Strategy.Count.\
    """

    @impl AshMetrics.Gauge.Strategy
    @spec compute(module(), AshMetrics.Dsl.Gauge.t(), keyword()) :: {:error, String.t()}
    def compute(_resource, _gauge, _opts), do: {:error, @missing}
  end
end
