defmodule AshMetrics.Integration.PostgresOldestAgeStrategyPostgresTest do
  # Seeds shared tables and tenant schemas in a real database, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Gauge.Strategy.OldestAge
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
    test "reports each group's oldest row as OldestAge does" do
      seed(PgTask, status: :pending, provider: "ses", inserted_at: ago(300))
      seed(PgTask, status: :pending, provider: "ses", inserted_at: ago(60))
      seed(PgTask, status: :pending, provider: nil, inserted_at: ago(120))
      seed(PgTask, status: :processing, provider: "smtp", inserted_at: ago(30))
      seed(PgTask, status: :pending, provider: "ses", inserted_at: ago(900), archived: true)
      seed(PgTask, status: :failed, provider: "ses", inserted_at: ago(900))
      seed(PgTask, status: :done, provider: "ses", inserted_at: ago(900))

      assert [
               {%{provider: nil, status: :pending}, unnamed},
               {%{provider: "ses", status: :pending}, pending},
               {%{provider: "smtp", status: :processing}, processing}
             ] = equivalent(PgTask, :backlog_age)

      assert unnamed in 120..122
      assert pending in 300..302
      assert processing in 30..32
    end

    test "measures a naive timestamp, ignoring nil, as OldestAge does" do
      seed(PgTask, status: :pending, queued_at: nil)
      seed(PgTask, status: :pending, queued_at: naive_ago(240))
      seed(PgTask, status: :processing, queued_at: naive_ago(30))
      seed(PgTask, status: :failed, queued_at: naive_ago(3_600))

      assert [{%{}, age}] = equivalent(PgTask, :queue_age)
      assert age in 240..242
    end

    test "reads 0 when every matching row holds nil, as OldestAge does" do
      seed(PgTask, status: :pending, queued_at: nil)

      assert equivalent(PgTask, :queue_age) == [{%{}, 0}]
    end

    test "returns what OldestAge returns for an empty table" do
      assert equivalent(PgTask, :backlog_age) == []
      assert equivalent(PgTask, :queue_age) == [{%{}, 0}]
    end

    test "reads 0 for a row written after the poll, as OldestAge does" do
      seed(PgTask, status: :pending, provider: "ses", inserted_at: ago(-600))

      assert equivalent(PgTask, :backlog_age) == [{%{provider: "ses", status: :pending}, 0}]
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

      assert {:ok, groups} =
               Postgres.OldestAge.compute(PgTask, Info.metric!(PgTask, :backlog_age), [])

      assert length(groups) == 6

      assert_received :queried
      refute_received :queried
    end
  end

  describe "a resource whose primary read action is distinct" do
    test "reports each group's oldest row as OldestAge does" do
      seed(PgLatestTask, status: :pending, provider: "ses", inserted_at: ago(300))
      seed(PgLatestTask, status: :pending, provider: "ses", inserted_at: ago(200))
      seed(PgLatestTask, status: :done, provider: "ses", inserted_at: ago(100))
      seed(PgLatestTask, status: :pending, provider: "smtp", inserted_at: ago(400))

      assert [{%{status: :done}, done}, {%{status: :pending}, pending}] =
               equivalent(PgLatestTask, :latest_age)

      assert done in 100..102
      assert pending in 400..402
    end
  end

  describe "a resource whose primary read action is limited" do
    test "reports each group's oldest row as OldestAge does while every row is within the limit" do
      seed(PgLimitedTask, status: :pending, inserted_at: ago(200))
      seed(PgLimitedTask, status: :done, inserted_at: ago(100))

      assert [{%{status: :done}, done}, {%{status: :pending}, pending}] =
               equivalent(PgLimitedTask, :limited_age)

      assert done in 100..102
      assert pending in 200..202
    end

    test "groups by the uuid primary key as OldestAge does" do
      first = seed(PgLimitedTask, status: :pending, inserted_at: ago(200))
      second = seed(PgLimitedTask, status: :done, inserted_at: ago(100))

      groups = equivalent(PgLimitedTask, gauge(PgLimitedTask, :limited_age, group_by: [:id]))

      assert Enum.map(groups, &elem(&1, 0)) == Enum.sort([%{id: first.id}, %{id: second.id}])
    end
  end

  describe "a gauge filtering through a to-many relationship" do
    setup do
      noted = seed(PgTask, status: :pending, provider: "ses", inserted_at: ago(300))
      seed(PgTaskNote, task_id: noted.id)
      seed(PgTaskNote, task_id: noted.id)

      also_noted =
        seed(PgTask,
          status: :pending,
          provider: "ses",
          inserted_at: ago(100),
          queued_at: naive_ago(240)
        )

      seed(PgTaskNote, task_id: also_noted.id)

      processing = seed(PgTask, status: :processing, provider: nil, inserted_at: ago(60))
      seed(PgTaskNote, task_id: processing.id)

      seed(PgTask, status: :pending, provider: "ses", inserted_at: ago(900))

      %{ids: Enum.sort([noted.id, also_noted.id, processing.id])}
    end

    test "reports each group's oldest row as OldestAge does" do
      gauge = gauge(PgTask, :backlog_age, filter: Ash.Expr.expr(not is_nil(notes.id)))

      assert [
               {%{provider: nil, status: :processing}, processing},
               {%{provider: "ses", status: :pending}, pending}
             ] = equivalent(PgTask, gauge)

      assert processing in 60..62
      assert pending in 300..302
    end

    test "measures a naive timestamp, ignoring nil, as OldestAge does" do
      gauge = gauge(PgTask, :queue_age, filter: Ash.Expr.expr(not is_nil(notes.id)))

      assert [{%{}, age}] = equivalent(PgTask, gauge)
      assert age in 240..242
    end

    test "groups by the uuid primary key as OldestAge does", %{ids: ids} do
      gauge =
        gauge(PgTask, :backlog_age, filter: Ash.Expr.expr(not is_nil(notes.id)), group_by: [:id])

      assert Enum.map(equivalent(PgTask, gauge), &elem(&1, 0)) == Enum.map(ids, &%{id: &1})
    end

    test "reports a filter on an aggregate as OldestAge does" do
      gauge = gauge(PgTask, :backlog_age, filter: Ash.Expr.expr(note_count > 1))

      assert [{%{provider: "ses", status: :pending}, age}] = equivalent(PgTask, gauge)
      assert age in 300..302
    end

    test "reports a filter on exists as OldestAge does" do
      gauge = gauge(PgTask, :backlog_age, filter: Ash.Expr.expr(exists(notes, true)))

      assert [
               {%{provider: nil, status: :processing}, processing},
               {%{provider: "ses", status: :pending}, pending}
             ] = equivalent(PgTask, gauge)

      assert processing in 60..62
      assert pending in 300..302
    end
  end

  describe "a resource whose table is in a schema of its own" do
    test "reports each group's oldest row as OldestAge does" do
      seed(PgPrefixedTask, status: :pending, inserted_at: ago(300))
      seed(PgPrefixedTask, status: :pending, inserted_at: ago(60))
      seed(PgPrefixedTask, status: :done, inserted_at: ago(900))

      assert [{%{status: :pending}, age}] = equivalent(PgPrefixedTask, :backlog_age)
      assert age in 300..302
    end
  end

  describe "attribute multitenancy" do
    test "reports each tenant as OldestAge does" do
      seed(PgTenantTask, [status: :pending, org: "tenant_a", inserted_at: ago(60)], "tenant_a")
      seed(PgTenantTask, [status: :pending, org: "tenant_b", inserted_at: ago(120)], "tenant_b")
      seed(PgTenantTask, [status: :done, org: "tenant_b", inserted_at: ago(900)], "tenant_b")

      assert [
               {%{status: :pending, tenant: "tenant_a"}, a},
               {%{status: :pending, tenant: "tenant_b"}, b}
             ] = equivalent(PgTenantTask, :backlog_age)

      assert a in 60..62
      assert b in 120..122
    end

    test "requires a tenant as OldestAge does" do
      gauge = Info.metric!(PgTenantTask, :backlog_age)

      assert {:error, %Ash.Error.Invalid{}} = OldestAge.compute(PgTenantTask, gauge, [])
      assert {:error, %Ash.Error.Invalid{}} = Postgres.OldestAge.compute(PgTenantTask, gauge, [])
    end

    test "reports every tenant at once with global? true as OldestAge does" do
      seed(PgGlobalTenantTask, status: :pending, org: "tenant_a", inserted_at: ago(60))
      seed(PgGlobalTenantTask, status: :pending, org: "tenant_b", inserted_at: ago(120))
      seed(PgGlobalTenantTask, status: :pending, org: "tenant_b", inserted_at: ago(30))

      assert [
               {%{status: :pending, tenant: "tenant_a"}, a},
               {%{status: :pending, tenant: "tenant_b"}, b}
             ] = equivalent(PgGlobalTenantTask, :backlog_age)

      assert a in 60..62
      assert b in 120..122
    end
  end

  describe "context multitenancy" do
    test "reports each tenant's schema as OldestAge does" do
      seed(PgSchemaTask, [status: :pending, inserted_at: ago(60)], "tenant_a")
      seed(PgSchemaTask, [status: :processing, inserted_at: ago(120)], "tenant_b")
      seed(PgSchemaTask, [status: :done, inserted_at: ago(900)], "tenant_b")

      assert [
               {%{status: :pending, tenant: "tenant_a"}, a},
               {%{status: :processing, tenant: "tenant_b"}, b}
             ] = equivalent(PgSchemaTask, :backlog_age)

      assert a in 60..62
      assert b in 120..122
    end
  end

  # Polls the gauge, or the declared gauge `name`, then the same gauge under
  # `OldestAge`, asserts that both return the same groups with the same ages,
  # and returns them. The second poll's clock is the later one, so its ages
  # may be a second older.
  defp equivalent(resource, %AshMetrics.Dsl.Gauge{} = gauge) do
    assert {:ok, grouped} = Runner.poll(resource, gauge)
    assert {:ok, read} = Runner.poll(resource, %{gauge | strategy: OldestAge})

    grouped = Enum.sort(grouped)
    read = Enum.sort(read)

    assert Enum.map(grouped, &elem(&1, 0)) == Enum.map(read, &elem(&1, 0))

    for {{_tags, from_postgres}, {_same, from_ash}} <- Enum.zip(grouped, read),
        do: assert((from_ash - from_postgres) in 0..1)

    grouped
  end

  defp equivalent(resource, name), do: equivalent(resource, Info.metric!(resource, name))

  # The declared gauge `name` with `overrides` applied.
  defp gauge(resource, name, overrides), do: struct!(Info.metric!(resource, name), overrides)

  defp seed(resource, attrs, tenant \\ nil),
    do: Ash.create!(resource, Map.new(attrs), tenant: tenant, authorize?: false)

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp naive_ago(seconds),
    do: seconds |> ago() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
end
