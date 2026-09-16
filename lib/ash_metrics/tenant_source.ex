defmodule AshMetrics.TenantSource do
  @moduledoc """
  Lists the tenants a gauge has to be polled for.

  Needed by an application whose gauges have to be polled once per tenant,
  which is the case for a resource using Ash's `:context` multitenancy
  strategy, where each tenant's rows live in their own schema, and for one
  using the `:attribute` strategy without `global? true`, which Ash refuses to
  read without a tenant. Either way a query has to name the tenant it is
  about, and there is no way to ask the resource which tenants exist, so the
  application has to say:

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

  A gauge that is polled per tenant costs a period the cost of the gauge
  multiplied by the number of tenants this returns — with the default strategy, `tenants * (1 + groups)`
  queries. Returning a long list of tenants for a gauge with a short period is
  the most expensive thing this package can be asked to do.
  """

  @doc """
  The tenants to poll every per-tenant gauge for.

  Called once per poll of such a gauge, not once at startup, so a tenant added
  while the application runs is picked up without a restart. It is therefore
  worth making cheap: cache it, or read it from something already in memory,
  rather than querying every tenant's table.
  """
  @callback list_tenants() :: [term()]
end
