defmodule AshMetrics.Test.Tenants do
  @moduledoc false
  # The tenants of `AshMetrics.Test.SchemaJob`, which uses `:context`
  # multitenancy and therefore has one ETS table per tenant.

  @behaviour AshMetrics.TenantSource

  @impl AshMetrics.TenantSource
  @spec list_tenants() :: [String.t()]
  def list_tenants, do: ["tenant_a", "tenant_b"]
end
