defmodule AshMetrics.Gauge.Runner do
  @moduledoc """
  Polls one gauge once, with or without emitting the result.

  A poll asks the gauge's `AshMetrics.Gauge.Strategy` for the current value of
  every group. `poll/2` returns those values; `emit/3` executes one
  `:telemetry` event per group as well and reports which groups were found, or
  hands the groups to a configured `AshMetrics.Backend` implementing
  `c:AshMetrics.Backend.report_gauge/3` and executes no event at all. An
  `AshMetrics.Poller` decides *when* to poll and calls this module; call it by
  hand from a test, an IEx session, or an application that schedules gauges
  itself.

  ## Multitenancy

  How a resource is polled depends on what Ash will let a query do. Every
  emission carries the tenant as the `tenant` tag, whichever case applies.

  * A resource with no multitenancy is polled once.
  * A resource using the `:attribute` strategy with `global? true` is polled
    once as well, with its tenant attribute appended to the gauge's grouping.
    One query therefore covers every tenant, and the attribute's value is
    emitted as the `tenant` tag. The attribute is left in the tags under its
    own name too when the resource declared it in `group_by` itself.
  * A resource using the `:attribute` strategy without `global? true` is polled
    once per tenant of the configured `AshMetrics.TenantSource`, each poll
    naming its tenant, because Ash refuses a read of such a resource that names
    no tenant.
  * A resource using the `:context` strategy is polled once per tenant as well,
    since each tenant's rows live in their own schema.

  ## Groups that vanish

  A `last_value` metric keeps reporting the last thing it was told, so a gauge
  grouped by status that drains from `%{status: :pending} => 12` to nothing at
  all would sit at 12 forever.

  `emit/3` is given the groups the previous poll found and emits a zero for
  every one of them that is missing from this poll, once. It returns the groups
  it found, for the caller to hand back next time. Nothing is zeroed for a
  backend that takes the groups through `c:AshMetrics.Backend.report_gauge/3`.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Backend
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy

  @typedoc "Groups emitted by an earlier poll, to be zeroed when they vanish."
  @type known_groups :: [AshMetrics.tags()] | MapSet.t(AshMetrics.tags())

  @typep collected :: {:ok, [Strategy.group()]} | {:error, term(), [Strategy.group()]}

  @doc """
  Polls `gauge` on `resource` and returns one value per group.

  Returns `{:ok, groups}`, each group a `{tags, value}` tuple tagged as the
  resource's multitenancy case dictates, or `{:error, reason}` from the
  gauge's strategy. Nothing is emitted and no group is zeroed; `emit/3` does
  both.

  An error the strategy returns is returned; an exception it raises is not
  caught here.
  """
  @spec poll(module(), Gauge.t()) :: {:ok, [Strategy.group()]} | {:error, term()}
  def poll(resource, %Gauge{} = gauge) do
    case collect(resource, gauge) do
      {:ok, groups} -> {:ok, groups}
      {:error, error, _computed} -> {:error, error}
    end
  end

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

  A configured `AshMetrics.Backend` implementing
  `c:AshMetrics.Backend.report_gauge/3` is handed the groups of a successful
  poll instead: no `:telemetry` event is executed, `known_groups` is ignored,
  and a failed poll reports nothing at all, not even the groups computed
  before the error. The return value is the same either way.

  Errors are returned rather than raised, but a strategy that raises is not
  caught here; `AshMetrics.Poller.GenServer` is what keeps a raising strategy
  from taking a poller down.
  """
  @spec emit(module(), Gauge.t(), known_groups()) ::
          {:ok, [AshMetrics.tags()]} | {:error, term()}
  def emit(resource, %Gauge{} = gauge, known_groups \\ []) do
    if Backend.reports_gauges?() do
      report(resource, gauge)
    else
      execute_each(resource, gauge, known_groups)
    end
  end

  @spec report(module(), Gauge.t()) :: {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp report(resource, %Gauge{} = gauge) do
    case collect(resource, gauge) do
      {:ok, groups} ->
        :ok = Config.backend().report_gauge(resource, gauge, groups)

        {:ok, Enum.map(groups, fn {tags, _value} -> tags end)}

      {:error, error, _computed} ->
        {:error, error}
    end
  end

  @spec execute_each(module(), Gauge.t(), known_groups()) ::
          {:ok, [AshMetrics.tags()]} | {:error, term()}
  defp execute_each(resource, %Gauge{} = gauge, known_groups) do
    case collect(resource, gauge) do
      {:ok, groups} ->
        emitted = execute_all(resource, gauge, groups)
        zero_vanished(resource, gauge, emitted, known_groups)

        {:ok, emitted}

      {:error, error, computed} ->
        execute_all(resource, gauge, computed)

        {:error, error}
    end
  end

  @spec collect(module(), Gauge.t()) :: collected()
  defp collect(resource, %Gauge{} = gauge) do
    case ResourceInfo.multitenancy_strategy(resource) do
      nil -> compute(resource, gauge, gauge, nil, &Function.identity/1)
      :attribute -> collect_attribute(resource, gauge)
      :context -> collect_per_tenant(resource, gauge)
    end
  end

  @spec collect_attribute(module(), Gauge.t()) :: collected()
  defp collect_attribute(resource, %Gauge{} = gauge) do
    if ResourceInfo.multitenancy_global?(resource) do
      attribute = ResourceInfo.multitenancy_attribute(resource)
      grouped = %{gauge | group_by: group_by(gauge, attribute)}

      compute(resource, gauge, grouped, nil, &as_tenant(&1, attribute, gauge.group_by))
    else
      collect_per_tenant(resource, gauge)
    end
  end

  @spec collect_per_tenant(module(), Gauge.t()) :: collected()
  defp collect_per_tenant(resource, %Gauge{} = gauge) do
    Enum.reduce_while(Config.tenant_source!().list_tenants(), {:ok, []}, fn tenant, {:ok, all} ->
      case compute(resource, gauge, gauge, tenant, &Map.put(&1, :tenant, tenant)) do
        {:ok, groups} -> {:cont, {:ok, all ++ groups}}
        {:error, error, _computed} -> {:halt, {:error, error, all}}
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
        ) :: collected()
  defp compute(resource, %Gauge{} = gauge, %Gauge{} = queried, tenant, tags) do
    case Gauge.strategy_module(gauge).compute(resource, queried, tenant: tenant) do
      {:ok, groups} ->
        {:ok, Enum.map(groups, fn {group, value} -> {tags.(group), value} end)}

      {:error, error} ->
        {:error, error, []}
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

  @spec execute_all(module(), Gauge.t(), [Strategy.group()]) :: [AshMetrics.tags()]
  defp execute_all(resource, gauge, groups) do
    Enum.map(groups, fn {tags, value} -> execute(resource, gauge, tags, value) end)
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
