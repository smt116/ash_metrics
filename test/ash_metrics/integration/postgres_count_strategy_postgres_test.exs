defmodule AshMetrics.Integration.PostgresCountStrategyPostgresTest do
  # Seeds shared tables and tenant schemas in a real database, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Gauge.Strategy.Count
  alias AshMetrics.Gauge.Strategy.Postgres
  alias AshMetrics.Info
  alias AshMetrics.Test.PgGlobalTenantTask
  alias AshMetrics.Test.PgLatestTask
  alias AshMetrics.Test.PgLimitedTask
  alias AshMetrics.Test.PgPrefixedTask
  alias AshMetrics.Test.PgSchemaTask
  alias AshMetrics.Test.PgTask
  alias AshMetrics.Test.PgTaskNote
  alias AshMetrics.Test.PgTasks
  alias AshMetrics.Test.PgTenantTask

  require Ash.Expr

  setup_all do
    PgTasks.create_tenants!()
    on_exit(&PgTasks.drop_tenants!/0)
  end

  setup do
    PgTasks.clear!()
    on_exit(&PgTasks.clear!/0)
  end

  describe "a resource with a base filter and a preparing primary read action" do
    test "counts each group as Count does" do
      seed(PgTask, status: :pending, provider: "ses")
      seed(PgTask, status: :pending, provider: "ses")
      seed(PgTask, status: :pending, provider: nil)
      seed(PgTask, status: :processing, provider: "smtp")
      seed(PgTask, status: :pending, provider: "ses", archived: true)
      seed(PgTask, status: :failed, provider: "ses")
      seed(PgTask, status: :done, provider: "ses")

      assert equivalent(PgTask, :backlog) == [
               {%{provider: nil, status: :pending}, 1},
               {%{provider: "ses", status: :pending}, 2},
               {%{provider: "smtp", status: :processing}, 1}
             ]
    end

    test "counts every row as Count does" do
      seed(PgTask, status: :pending)
      seed(PgTask, status: :done)
      seed(PgTask, status: :failed)
      seed(PgTask, status: :pending, archived: true)

      assert equivalent(PgTask, :total) == [{%{}, 2}]
    end

    test "returns what Count returns for an empty table" do
      assert equivalent(PgTask, :backlog) == []
      assert equivalent(PgTask, :total) == [{%{}, 0}]
    end

    test "runs one query whatever the number of groups" do
      for status <- [:pending, :processing],
          provider <- ["ses", "smtp", "sns"],
          do: seed(PgTask, status: status, provider: provider)

      handler = {__MODULE__, System.unique_integer([:positive])}
      test = self()

      :telemetry.attach(
        handler,
        [:ash_metrics, :test, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test, :queried) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, groups} = Postgres.Count.compute(PgTask, Info.metric!(PgTask, :backlog), [])
      assert length(groups) == 6

      assert_received :queried
      refute_received :queried
    end
  end

  describe "a resource whose primary read action is distinct" do
    test "counts each group as Count does" do
      seed(PgLatestTask, status: :pending, provider: "ses", inserted_at: ago(300))
      seed(PgLatestTask, status: :pending, provider: "ses", inserted_at: ago(200))
      seed(PgLatestTask, status: :done, provider: "ses", inserted_at: ago(100))
      seed(PgLatestTask, status: :pending, provider: "smtp", inserted_at: ago(100))
      seed(PgLatestTask, status: :failed, provider: nil, inserted_at: ago(100))
      seed(PgLatestTask, status: :failed, provider: nil, inserted_at: ago(50))

      assert equivalent(PgLatestTask, :latest) == [
               {%{status: :done}, 1},
               {%{status: :failed}, 1},
               {%{status: :pending}, 2}
             ]
    end

    test "counts every row as Count does" do
      seed(PgLatestTask, status: :pending, provider: "ses")
      seed(PgLatestTask, status: :done, provider: "ses")
      seed(PgLatestTask, status: :pending, provider: "smtp")
      seed(PgLatestTask, status: :pending, provider: nil)

      assert equivalent(PgLatestTask, :total) == [{%{}, 3}]
    end
  end

  describe "a resource whose primary read action is limited" do
    test "counts each group as Count does while every row is within the limit" do
      seed(PgLimitedTask, status: :pending, inserted_at: ago(200))
      seed(PgLimitedTask, status: :done, inserted_at: ago(100))

      assert equivalent(PgLimitedTask, :limited) == [
               {%{status: :done}, 1},
               {%{status: :pending}, 1}
             ]
    end

    test "groups by the uuid primary key as Count does" do
      first = seed(PgLimitedTask, status: :pending, inserted_at: ago(200))
      second = seed(PgLimitedTask, status: :done, inserted_at: ago(100))

      assert equivalent(PgLimitedTask, gauge(PgLimitedTask, :limited, group_by: [:id])) ==
               Enum.sort([{%{id: first.id}, 1}, {%{id: second.id}, 1}])
    end

    test "counts only the rows the limited read returns" do
      seed(PgLimitedTask, status: :pending, inserted_at: ago(400))
      seed(PgLimitedTask, status: :done, inserted_at: ago(300))
      seed(PgLimitedTask, status: :failed, inserted_at: ago(200))
      seed(PgLimitedTask, status: :failed, inserted_at: ago(100))

      assert {:ok, groups} =
               Postgres.Count.compute(PgLimitedTask, Info.metric!(PgLimitedTask, :limited), [])

      assert Enum.sort(groups) == [{%{status: :done}, 1}, {%{status: :pending}, 1}]
    end
  end

  describe "a gauge filtering through a to-many relationship" do
    setup do
      noted = seed(PgTask, status: :pending, provider: "ses")
      seed(PgTaskNote, task_id: noted.id)
      seed(PgTaskNote, task_id: noted.id)

      also_noted = seed(PgTask, status: :pending, provider: "ses")
      seed(PgTaskNote, task_id: also_noted.id)

      processing = seed(PgTask, status: :processing, provider: nil)
      seed(PgTaskNote, task_id: processing.id)

      seed(PgTask, status: :pending, provider: "ses")

      %{ids: Enum.sort([noted.id, also_noted.id, processing.id])}
    end

    test "counts each group as Count does" do
      gauge = gauge(PgTask, :backlog, filter: Ash.Expr.expr(not is_nil(notes.id)))

      assert equivalent(PgTask, gauge) == [
               {%{provider: nil, status: :processing}, 1},
               {%{provider: "ses", status: :pending}, 2}
             ]
    end

    test "counts every row as Count does" do
      gauge = gauge(PgTask, :total, filter: Ash.Expr.expr(not is_nil(notes.id)))

      assert equivalent(PgTask, gauge) == [{%{}, 3}]
    end

    test "groups by the uuid primary key as Count does", %{ids: ids} do
      gauge =
        gauge(PgTask, :backlog, filter: Ash.Expr.expr(not is_nil(notes.id)), group_by: [:id])

      assert equivalent(PgTask, gauge) == Enum.map(ids, &{%{id: &1}, 1})
    end

    test "counts a filter on an aggregate as Count does" do
      gauge = gauge(PgTask, :backlog, filter: Ash.Expr.expr(note_count > 1))

      assert equivalent(PgTask, gauge) == [{%{provider: "ses", status: :pending}, 1}]
    end

    test "counts a filter on exists as Count does" do
      gauge = gauge(PgTask, :backlog, filter: Ash.Expr.expr(exists(notes, true)))

      assert equivalent(PgTask, gauge) == [
               {%{provider: nil, status: :processing}, 1},
               {%{provider: "ses", status: :pending}, 2}
             ]
    end
  end

  describe "a resource whose table is in a schema of its own" do
    test "counts each group as Count does" do
      seed(PgPrefixedTask, status: :pending)
      seed(PgPrefixedTask, status: :pending)
      seed(PgPrefixedTask, status: :processing)
      seed(PgPrefixedTask, status: :done)

      assert equivalent(PgPrefixedTask, :backlog) == [
               {%{status: :pending}, 2},
               {%{status: :processing}, 1}
             ]
    end
  end

  describe "attribute multitenancy" do
    test "counts each tenant as Count does" do
      seed(PgTenantTask, [status: :pending, org: "tenant_a"], "tenant_a")
      seed(PgTenantTask, [status: :pending, org: "tenant_b"], "tenant_b")
      seed(PgTenantTask, [status: :processing, org: "tenant_b"], "tenant_b")
      seed(PgTenantTask, [status: :done, org: "tenant_b"], "tenant_b")

      assert equivalent(PgTenantTask, :backlog) == [
               {%{status: :pending, tenant: "tenant_a"}, 1},
               {%{status: :pending, tenant: "tenant_b"}, 1},
               {%{status: :processing, tenant: "tenant_b"}, 1}
             ]
    end

    test "requires a tenant as Count does" do
      gauge = Info.metric!(PgTenantTask, :backlog)

      assert {:error, %Ash.Error.Invalid{}} = Count.compute(PgTenantTask, gauge, [])
      assert {:error, %Ash.Error.Invalid{}} = Postgres.Count.compute(PgTenantTask, gauge, [])
    end

    test "counts every tenant at once with global? true as Count does" do
      seed(PgGlobalTenantTask, status: :pending, org: "tenant_a")
      seed(PgGlobalTenantTask, status: :pending, org: "tenant_b")
      seed(PgGlobalTenantTask, status: :pending, org: "tenant_b")
      seed(PgGlobalTenantTask, status: :done, org: "tenant_b")

      assert equivalent(PgGlobalTenantTask, :backlog) == [
               {%{status: :pending, tenant: "tenant_a"}, 1},
               {%{status: :pending, tenant: "tenant_b"}, 2}
             ]
    end
  end

  describe "context multitenancy" do
    test "counts each tenant's schema as Count does" do
      seed(PgSchemaTask, [status: :pending], "tenant_a")
      seed(PgSchemaTask, [status: :pending], "tenant_b")
      seed(PgSchemaTask, [status: :processing], "tenant_b")
      seed(PgSchemaTask, [status: :done], "tenant_b")

      assert equivalent(PgSchemaTask, :backlog) == [
               {%{status: :pending, tenant: "tenant_a"}, 1},
               {%{status: :pending, tenant: "tenant_b"}, 1},
               {%{status: :processing, tenant: "tenant_b"}, 1}
             ]
    end
  end

  # Polls the gauge, or the declared gauge `name`, and the same gauge under
  # `:count`, asserts that both return the same groups, and returns them.
  defp equivalent(resource, %AshMetrics.Dsl.Gauge{} = gauge) do
    assert {:ok, counted} = Runner.poll(resource, %{gauge | strategy: :count, strategy_opts: []})
    assert {:ok, grouped} = Runner.poll(resource, gauge)
    assert Enum.sort(grouped) == Enum.sort(counted)

    Enum.sort(grouped)
  end

  defp equivalent(resource, name), do: equivalent(resource, Info.metric!(resource, name))

  # The declared gauge `name` with `overrides` applied.
  defp gauge(resource, name, overrides), do: struct!(Info.metric!(resource, name), overrides)

  defp seed(resource, attrs, tenant \\ nil),
    do: Ash.create!(resource, Map.new(attrs), tenant: tenant, authorize?: false)

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
end
