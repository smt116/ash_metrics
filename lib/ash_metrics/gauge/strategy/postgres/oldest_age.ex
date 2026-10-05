if Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AshMetrics.Gauge.Strategy.Postgres.OldestAge do
    @moduledoc """
    Reports, per group, the age of the oldest row matching a gauge, every
    group in one query.

    Takes the options of `AshMetrics.Gauge.Strategy.OldestAge` and returns
    what it returns on the same rows, from a single `GROUP BY` statement per
    poll, or per tenant for a resource `AshMetrics.Gauge.Runner` polls per
    tenant, in place of `1 + groups`.

        gauge :backlog_age,
          filter: expr(status == :pending),
          group_by: [:provider],
          strategy: {AshMetrics.Gauge.Strategy.Postgres.OldestAge, attribute: :queued_at}

    The statement is the one `AshMetrics.Gauge.Strategy.Postgres.Count`
    builds, with the minimum of `attribute` in place of the count, and shares
    that strategy's caveat on a primary read action limited or offset by its
    preparations.

    A gauge is rejected while its resource compiles for what
    `AshMetrics.Gauge.Strategy.OldestAge` rejects, and when the resource's
    data layer is not `AshPostgres.DataLayer`.

    Needs `ash_postgres`; see `AshMetrics.Gauge.Strategy.Postgres.Transformer`.
    """

    @behaviour AshMetrics.Gauge.Strategy

    import Ecto.Query

    alias AshMetrics.Dsl.Gauge
    alias AshMetrics.Gauge.Strategy
    alias AshMetrics.Gauge.Strategy.OldestAge
    alias AshMetrics.Gauge.Strategy.Postgres.Query

    @impl AshMetrics.Gauge.Strategy
    @spec verify(Spark.Dsl.t(), Gauge.t()) :: :ok | {:error, String.t()}
    def verify(dsl_state, %Gauge{} = gauge) do
      with :ok <- Query.verify(dsl_state), do: OldestAge.verify(dsl_state, gauge)
    end

    @impl AshMetrics.Gauge.Strategy
    @spec compute(module(), Gauge.t(), keyword()) ::
            {:ok, [Strategy.group()]} | {:error, term()}
    def compute(resource, %Gauge{} = gauge, opts) do
      attribute = OldestAge.attribute(gauge)
      now = DateTime.utc_now()

      with {:ok, query} <- Query.rows(resource, gauge, opts),
           do: oldest_ages(resource, query, gauge.group_by, attribute, now)
    end

    @spec oldest_ages(module(), Ecto.Query.t(), [atom()], atom(), DateTime.t()) ::
            {:ok, [Strategy.group()]} | {:error, term()}
    defp oldest_ages(resource, query, [], attribute, now) do
      with {:ok, oldest} <- Query.one(resource, select(query, ^oldest(attribute))),
           {:ok, age} <- age(resource, attribute, oldest, now),
           do: {:ok, [{%{}, age}]}
    end

    defp oldest_ages(resource, query, group_by, attribute, now) do
      Query.grouped(
        resource,
        query,
        group_by,
        oldest(attribute),
        &age(resource, attribute, &1, now)
      )
    end

    @spec age(module(), atom(), term(), DateTime.t()) ::
            {:ok, non_neg_integer()} | {:error, String.t()}
    defp age(resource, attribute, oldest, now) do
      with {:ok, oldest} <- Query.cast(resource, attribute, oldest),
           do: {:ok, OldestAge.age(oldest, now)}
    end

    @spec oldest(atom()) :: Ecto.Query.dynamic_expr()
    defp oldest(attribute), do: dynamic([row], fragment("min(?)", field(row, ^attribute)))
  end
else
  defmodule AshMetrics.Gauge.Strategy.Postgres.OldestAge do
    @moduledoc """
    Reports, per group, the age of the oldest row matching a gauge, every
    group in one query.

    This is the stub compiled when `ash_postgres` is not available; see
    `AshMetrics.Gauge.Strategy.Postgres.Transformer`. Computing one returns an
    error.
    """

    @behaviour AshMetrics.Gauge.Strategy

    @missing """
    AshMetrics.Gauge.Strategy.Postgres.OldestAge needs the `ash_postgres` \
    package, which is not available. Add it to your dependencies, \
    `{:ash_postgres, "~> 2.13"}`, or choose another strategy, such as \
    AshMetrics.Gauge.Strategy.OldestAge.\
    """

    @impl AshMetrics.Gauge.Strategy
    @spec compute(module(), AshMetrics.Dsl.Gauge.t(), keyword()) :: {:error, String.t()}
    def compute(_resource, _gauge, _opts), do: {:error, @missing}
  end
end
