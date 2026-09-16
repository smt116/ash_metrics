defmodule AshMetrics.Verifiers.VerifyTenantSource do
  @moduledoc """
  Rejects a `:context` multitenant resource that declares a gauge while
  `tenant_source` is unset.

  A gauge on such a resource is polled once per tenant, because each tenant's
  rows live in their own schema, and nothing but the application can say which
  tenants exist. Without a source the gauge would be polled for no tenant at
  all and emit nothing — a metric that looks configured and reports nothing,
  which is the failure this package exists to prevent.

  Nothing is checked for the `:attribute` strategy: its tenants are values of
  one of the resource's own attributes, and one query grouped by that attribute
  covers every tenant.

  Like every Spark verifier, a failure is reported by the compiler as a warning
  pointing at the resource, not as a hard error. Compile with
  `--warnings-as-errors` to turn it into one.
  """

  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Gauge
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl Spark.Dsl.Verifier
  @spec verify(map()) :: :ok | {:error, Exception.t()}
  def verify(dsl_state) do
    if needs_tenant_source?(dsl_state) and is_nil(Config.tenant_source()) do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:metrics],
         message: """
         `tenant_source` must be set to a module implementing \
         `AshMetrics.TenantSource` in the compile-time configuration of \
         :ash_metrics.

         Add this to `config/config.exs`:

             config :ash_metrics, tenant_source: MyApp.Tenants

         This resource uses Ash's `:context` multitenancy strategy, so each
         gauge declared here is polled once per tenant, and only the
         application can say which tenants exist.
         """
       )}
    else
      :ok
    end
  end

  @spec needs_tenant_source?(map()) :: boolean()
  defp needs_tenant_source?(dsl_state) do
    ResourceInfo.multitenancy_strategy(dsl_state) == :context and gauges?(dsl_state)
  end

  @spec gauges?(map()) :: boolean()
  defp gauges?(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:metrics])
    |> Enum.any?(&match?(%Gauge{}, &1))
  end
end
