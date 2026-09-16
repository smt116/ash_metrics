defmodule AshMetrics.TenantSource do
  @moduledoc """
  Lists the tenants a gauge has to be polled for.

  Needed by exactly one shape of application: one whose resources use Ash's
  `:context` multitenancy strategy, where each tenant's rows live in their own
  schema and a query therefore has to name the tenant it is about. There is no
  way to ask such a resource how many tenants exist, so the application has to
  say:

      defmodule MyApp.Tenants do
        @behaviour AshMetrics.TenantSource

        @impl AshMetrics.TenantSource
        def list_tenants, do: MyApp.Accounts.list_organisation_slugs!()
      end

      config :ash_metrics, tenant_source: MyApp.Tenants

  A resource using the `:attribute` strategy needs none of this: its tenants
  are values of one of its own attributes, so one query grouped by that
  attribute covers all of them at once. A single-tenant application needs none
  of it either.

  ## Cost

  A gauge on a `:context` multitenant resource is polled once per tenant, so
  the cost of a period is the cost of the gauge multiplied by the number of
  tenants this returns — with the default strategy, `tenants * (1 + groups)`
  queries. Returning a long list of tenants for a gauge with a short period is
  the most expensive thing this package can be asked to do.
  """

  @doc """
  The tenants to poll every `:context` multitenant gauge for.

  Called once per poll of such a gauge, not once at startup, so a tenant added
  while the application runs is picked up without a restart. It is therefore
  worth making cheap: cache it, or read it from something already in memory,
  rather than querying every tenant's table.
  """
  @callback list_tenants() :: [term()]
end
