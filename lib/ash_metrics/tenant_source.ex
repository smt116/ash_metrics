defmodule AshMetrics.TenantSource do
  @moduledoc """
  Lists the tenants a gauge has to be polled for.

  Needed by an application whose gauges have to be polled once per tenant:
  those on a resource using Ash's `:context` multitenancy strategy, where each
  tenant's rows live in their own schema, and those on one using the
  `:attribute` strategy without `global? true`, which Ash refuses to read
  without a tenant. Such a query has to name its tenant, and nothing can ask
  the resource which tenants exist, so the application supplies them:

      defmodule MyApp.Tenants do
        @behaviour AshMetrics.TenantSource

        @impl AshMetrics.TenantSource
        def list_tenants, do: MyApp.Accounts.list_organisation_slugs!()
      end

      config :ash_metrics, tenant_source: MyApp.Tenants

  A resource using the `:attribute` strategy with `global? true` needs none of
  this: one query grouped by the tenant attribute covers every tenant at once.
  A single-tenant application needs none of it either.

  ## Cost

  A gauge that is polled per tenant costs, every period, the cost of the gauge
  multiplied by the number of tenants this returns. Mind that multiplier for a
  long tenant list or a short `period`.
  """

  @doc """
  The tenants to poll every per-tenant gauge for.

  Called once per poll of such a gauge, not once at startup, so a tenant added
  while the application runs is picked up without a restart. Keep it cheap:
  cache it, or read it from something already in memory.
  """
  @callback list_tenants() :: [term()]
end
