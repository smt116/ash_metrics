defmodule AshMetrics.Gauge.Runner do
  @moduledoc """
  Polls one gauge once and emits one measurement per group.

  This is the whole of what a poll is: ask the gauge's
  `AshMetrics.Gauge.Strategy` for the current value of every group, execute one
  `:telemetry` event per group, and report which groups were found. What
  decides *when* to poll is an `AshMetrics.Poller`; this module is what it
  calls, and is also what to call by hand from a test, an IEx session, or an
  application that would rather schedule gauges itself.

  ## Multitenancy

  What Ash allows is handled differently case by case, because the cases are
  different questions. Every emission carries the tenant as the `tenant` tag
  either way, so nothing downstream has to know which case a resource is.

  * A resource with no multitenancy is polled once.
  * A resource using the `:attribute` strategy with `global? true` is polled
    once as well, with its tenant attribute appended to the gauge's grouping.
    One query therefore covers every tenant, and the attribute's value is
    emitted as the `tenant` tag. The attribute is left in the tags under its
    own name too when the resource declared it in `group_by` itself.
  * A resource using the `:attribute` strategy without `global? true` is polled
    once per tenant of the configured `AshMetrics.TenantSource`, each poll
    naming its tenant, because Ash refuses a read of such a resource that names
    no tenant. Turning `global?` on to save the extra queries would widen
    tenantless reads for the whole application, which is not a trade a metric
    should ask anyone to make.
  * A resource using the `:context` strategy is polled once per tenant as well,
    since each tenant's rows live in their own schema.

  ## Groups that vanish

  A `last_value` metric keeps reporting the last thing it was told. A gauge
  grouped by status that drains from `%{status: :pending} => 12` to nothing at
  all would therefore sit at 12 forever, which is the opposite of what a gauge
  is for.

  `emit/3` is given the groups the previous poll found and emits a zero for
  every one of them that is missing from this poll, once. It returns the groups
  it found, for the caller to hand back next time.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Gauge

  @typedoc "Groups emitted by an earlier poll, to be zeroed when they vanish."
  @type known_groups :: [AshMetrics.tags()] | MapSet.t(AshMetrics.tags())

  @doc """
  Polls `gauge` on `resource` and emits one measurement per group.

  `known_groups` are the groups a previous poll found — the second element of
  its `{:ok, groups}` — and any of them that this poll does not find is emitted
  as a zero. Pass `[]` for the first poll.

  Returns `{:ok, groups}` with the groups this poll found, or `{:error,
  reason}` from the gauge's strategy. An error is not partial: measurements
  computed before it, for another tenant, have already been emitted, but
  nothing is zeroed, because a failed poll says nothing about which groups
  still exist. A caller that keeps the groups should keep the ones it had.

  Errors are returned rather than raised, but a strategy that raises is not
  caught here; `AshMetrics.Poller.GenServer` is what keeps a raising strategy
  from taking a poller down.
  """
  @spec emit(module(), Gauge.t(), known_groups()) ::
          {:ok, [AshMetrics.tags()]} | {:error, term()}
  def emit(resource, %Gauge{} = gauge, known_groups \\ []) do
    case poll(resource, gauge) do
      {:ok, groups} ->
        zero_vanished(resource, gauge, groups, known_groups)

        {:ok, groups}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec poll(module(), Gauge.t()) :: {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp poll(resource, %Gauge{} = gauge) do
    case ResourceInfo.multitenancy_strategy(resource) do
      nil -> compute(resource, gauge, gauge, nil, &Function.identity/1)
      :attribute -> poll_attribute(resource, gauge)
      :context -> poll_per_tenant(resource, gauge)
    end
  end

  @spec poll_attribute(module(), Gauge.t()) :: {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp poll_attribute(resource, %Gauge{} = gauge) do
    if ResourceInfo.multitenancy_global?(resource) do
      attribute = ResourceInfo.multitenancy_attribute(resource)
      grouped = %{gauge | group_by: group_by(gauge, attribute)}

      compute(resource, gauge, grouped, nil, &as_tenant(&1, attribute, gauge.group_by))
    else
      poll_per_tenant(resource, gauge)
    end
  end

  @spec poll_per_tenant(module(), Gauge.t()) :: {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp poll_per_tenant(resource, %Gauge{} = gauge) do
    Enum.reduce_while(Config.tenant_source!().list_tenants(), {:ok, []}, fn tenant, {:ok, all} ->
      case compute(resource, gauge, gauge, tenant, &Map.put(&1, :tenant, tenant)) do
        {:ok, groups} -> {:cont, {:ok, all ++ groups}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # `gauge` is the declaration, and decides the strategy and the metric name.
  # `queried` is what the strategy is asked about, which for attribute
  # multitenancy groups by one attribute more than was declared.
  @spec compute(
          module(),
          Gauge.t(),
          Gauge.t(),
          term(),
          (AshMetrics.tags() -> AshMetrics.tags())
        ) :: {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp compute(resource, %Gauge{} = gauge, %Gauge{} = queried, tenant, tags) do
    case Gauge.strategy_module(gauge).compute(resource, queried, tenant: tenant) do
      {:ok, groups} ->
        {:ok,
         Enum.map(groups, fn {group, value} -> execute(resource, gauge, tags.(group), value) end)}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec group_by(Gauge.t(), atom()) :: [atom()]
  defp group_by(%Gauge{group_by: group_by}, attribute) do
    if attribute in group_by, do: group_by, else: group_by ++ [attribute]
  end

  @spec as_tenant(AshMetrics.tags(), atom(), [atom()]) :: AshMetrics.tags()
  defp as_tenant(tags, attribute, declared) do
    tenant = Map.get(tags, attribute)
    tags = if attribute in declared, do: tags, else: Map.delete(tags, attribute)

    Map.put(tags, :tenant, tenant)
  end

  @spec zero_vanished(module(), Gauge.t(), [AshMetrics.tags()], known_groups()) :: :ok
  defp zero_vanished(resource, gauge, groups, known_groups) do
    known_groups
    |> Enum.uniq()
    |> Enum.reject(&(&1 in groups))
    |> Enum.each(&execute(resource, gauge, &1, 0))
  end

  @spec execute(module(), Gauge.t(), AshMetrics.tags(), number()) :: AshMetrics.tags()
  defp execute(resource, %Gauge{} = gauge, tags, value) do
    :telemetry.execute(AshMetrics.event_name(resource, gauge.name), %{value: value}, tags)

    tags
  end
end
