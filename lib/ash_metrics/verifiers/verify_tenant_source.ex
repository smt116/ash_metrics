defmodule AshMetrics.Verifiers.VerifyTenantSource do
  @moduledoc """
  Rejects a multitenant resource that declares a gauge which has to be polled
  per tenant while `tenant_source` is unset.

  Without a source such a gauge is polled for no tenant at all and emits
  nothing. `AshMetrics.TenantSource` lists the two shapes that have to be
  polled per tenant; nothing is checked for an `:attribute` multitenant
  resource with `global? true`, whose gauges are covered by one query.

  See `AshMetrics` for how a verifier failure is reported.
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

         #{reason(dsl_state)}

         Each gauge declared here is therefore polled once per tenant, and
         only the application can say which tenants exist.
         """
       )}
    else
      :ok
    end
  end

  @spec needs_tenant_source?(map()) :: boolean()
  defp needs_tenant_source?(dsl_state) do
    per_tenant?(dsl_state) and gauges?(dsl_state)
  end

  @spec per_tenant?(map()) :: boolean()
  defp per_tenant?(dsl_state) do
    case ResourceInfo.multitenancy_strategy(dsl_state) do
      :context -> true
      :attribute -> not ResourceInfo.multitenancy_global?(dsl_state)
      nil -> false
    end
  end

  @spec reason(map()) :: String.t()
  defp reason(dsl_state) do
    case ResourceInfo.multitenancy_strategy(dsl_state) do
      :context ->
        "This resource uses Ash's `:context` multitenancy strategy, so each " <>
          "tenant's rows live in their own schema."

      :attribute ->
        "This resource uses Ash's `:attribute` multitenancy strategy without " <>
          "`global? true`, so Ash refuses to read it without a tenant."
    end
  end

  @spec gauges?(map()) :: boolean()
  defp gauges?(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:metrics])
    |> Enum.any?(&match?(%Gauge{}, &1))
  end
end
