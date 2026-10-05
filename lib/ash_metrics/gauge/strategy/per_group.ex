defmodule AshMetrics.Gauge.Strategy.PerGroup do
  @moduledoc false
  # Computes a gauge one group at a time through Ash, for a strategy that
  # supplies the value of one query: a single call for a gauge with no
  # `group_by`, or one read of the distinct `group_by` values followed by one
  # call per group. Every read runs with `authorize?: false`.

  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy

  @typedoc "Computes the value of the rows one query matches."
  @type value :: (Ash.Query.t() -> {:ok, number()} | {:error, term()})

  @spec compute(module(), Gauge.t(), keyword(), value()) ::
          {:ok, [Strategy.group()]} | {:error, term()}
  def compute(resource, %Gauge{group_by: []} = gauge, opts, value) do
    case value.(query(resource, gauge, opts)) do
      {:ok, value} -> {:ok, [{%{}, value}]}
      {:error, error} -> {:error, error}
    end
  end

  def compute(resource, %Gauge{group_by: group_by} = gauge, opts, value) do
    query = query(resource, gauge, opts)

    case groups(query, group_by) do
      {:ok, groups} -> each(query, groups, value)
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

  @spec each(Ash.Query.t(), [AshMetrics.tags()], value()) ::
          {:ok, [Strategy.group()]} | {:error, term()}
  defp each(query, groups, value) do
    Enum.reduce_while(groups, {:ok, []}, fn tags, {:ok, computed} ->
      case value.(Ash.Query.do_filter(query, statement(tags))) do
        {:ok, value} -> {:cont, {:ok, [{tags, value} | computed]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, computed} -> {:ok, Enum.reverse(computed)}
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
end
