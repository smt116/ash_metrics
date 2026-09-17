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

  A resource where that is too expensive can declare its own
  `AshMetrics.Gauge.Strategy` — an estimate from the database's own statistics,
  a cached value, or a single hand-written query that collapses the per-group
  loop.

  Every query runs with `authorize?: false`, since a poll has no actor.
  """

  @behaviour AshMetrics.Gauge.Strategy

  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy

  @impl AshMetrics.Gauge.Strategy
  @spec compute(module(), Gauge.t(), keyword()) :: {:ok, [Strategy.group()]} | {:error, term()}
  def compute(resource, %Gauge{group_by: []} = gauge, opts) do
    case count(query(resource, gauge, opts)) do
      {:ok, count} -> {:ok, [{%{}, count}]}
      {:error, error} -> {:error, error}
    end
  end

  def compute(resource, %Gauge{group_by: group_by} = gauge, opts) do
    query = query(resource, gauge, opts)

    case groups(query, group_by) do
      {:ok, groups} -> count_each(query, groups)
      {:error, error} -> {:error, error}
    end
  end

  @spec query(module(), Gauge.t(), keyword()) :: Ash.Query.t()
  defp query(resource, %Gauge{} = gauge, opts) do
    resource
    |> Ash.Query.new()
    |> filter(gauge.filter)
    |> tenant(Keyword.get(opts, :tenant))
  end

  @spec filter(Ash.Query.t(), term()) :: Ash.Query.t()
  defp filter(query, nil), do: query
  defp filter(query, filter), do: Ash.Query.do_filter(query, filter)

  @spec tenant(Ash.Query.t(), term()) :: Ash.Query.t()
  defp tenant(query, nil), do: query
  defp tenant(query, tenant), do: Ash.Query.set_tenant(query, tenant)

  @spec groups(Ash.Query.t(), [atom()]) :: {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp groups(query, group_by) do
    query
    |> Ash.Query.select(group_by)
    |> Ash.Query.distinct(group_by)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, records} -> {:ok, Enum.map(records, &Map.take(&1, group_by))}
      {:error, error} -> {:error, error}
    end
  end

  @spec count_each(Ash.Query.t(), [AshMetrics.tags()]) ::
          {:ok, [Strategy.group()]} | {:error, term()}
  defp count_each(query, groups) do
    Enum.reduce_while(groups, {:ok, []}, fn tags, {:ok, counted} ->
      case count(Ash.Query.do_filter(query, statement(tags))) do
        {:ok, count} -> {:cont, {:ok, [{tags, count} | counted]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, counted} -> {:ok, Enum.reverse(counted)}
      {:error, error} -> {:error, error}
    end
  end

  # A group's value may legitimately be `nil`, and `attribute == nil` is not
  # true of a `nil` attribute in a filter: like SQL, Ash compares it as
  # unknown. Such a group is asked for by name instead.
  @spec statement(AshMetrics.tags()) :: keyword()
  defp statement(tags) do
    Enum.map(tags, fn
      {key, nil} -> {key, [is_nil: true]}
      {key, value} -> {key, value}
    end)
  end

  @spec count(Ash.Query.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp count(query), do: Ash.count(query, authorize?: false)
end
