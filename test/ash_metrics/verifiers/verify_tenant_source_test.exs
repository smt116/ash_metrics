defmodule AshMetrics.Verifiers.VerifyTenantSourceTest do
  # Deletes the configured tenant source, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.GlobalTenantJob
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.SchemaCounter
  alias AshMetrics.Test.SchemaJob
  alias AshMetrics.Test.TenantJob
  alias Spark.Error.DslError

  describe "without a configured tenant source" do
    setup do
      original = Application.get_env(:ash_metrics, :tenant_source)
      Application.delete_env(:ash_metrics, :tenant_source)

      on_exit(fn -> Application.put_env(:ash_metrics, :tenant_source, original) end)

      :ok
    end

    test "a :context multitenant resource declaring a gauge is rejected" do
      assert [%DslError{path: [:metrics]} = error] = Compiler.dsl_errors_for(SchemaJob)

      message = Exception.message(error)

      assert message =~ "`tenant_source` must be set to a module implementing"
      assert message =~ "config :ash_metrics, tenant_source: MyApp.Tenants"
      assert message =~ "each tenant's rows live in their own schema"
      assert message =~ "polled once per tenant"
    end

    test "a :context multitenant resource declaring no gauge is accepted" do
      assert Compiler.dsl_errors_for(SchemaCounter) == []
    end

    test "an :attribute multitenant resource declaring a gauge is rejected" do
      assert [%DslError{path: [:metrics]} = error] = Compiler.dsl_errors_for(TenantJob)

      message = Exception.message(error)

      assert message =~ "`tenant_source` must be set to a module implementing"
      assert message =~ "without `global? true`"
      assert message =~ "polled once per tenant"
    end

    test "a global :attribute multitenant resource declaring a gauge is accepted" do
      assert Compiler.dsl_errors_for(GlobalTenantJob) == []
    end

    test "a single tenant resource declaring a gauge is accepted" do
      assert Compiler.dsl_errors_for(Job) == []
    end
  end

  test "a resource polled per tenant is accepted once a source is configured" do
    assert Compiler.dsl_errors_for(SchemaJob) == []
    assert Compiler.dsl_errors_for(TenantJob) == []
  end
end
