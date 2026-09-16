defmodule AshMetrics.Gauge.RunnerTest.Failing do
  @moduledoc false
  # A strategy that fails, to prove that an error is returned rather than
  # emitted as a value.

  @behaviour AshMetrics.Gauge.Strategy

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts), do: {:error, :no_database}
end

defmodule AshMetrics.Gauge.RunnerTest.FailingForOneTenant do
  @moduledoc false
  # A strategy that answers for one tenant and fails for every other, to prove
  # that what was computed before an error is still emitted.

  @behaviour AshMetrics.Gauge.Strategy

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, opts) do
    case Keyword.fetch!(opts, :tenant) do
      "tenant_a" -> {:ok, [{%{status: :pending}, 3}]}
      other -> {:error, {:unreachable, other}}
    end
  end
end

defmodule AshMetrics.Gauge.RunnerTest do
  # Seeds shared ETS tables and attaches a telemetry handler, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Gauge.RunnerTest.Failing
  alias AshMetrics.Gauge.RunnerTest.FailingForOneTenant
  alias AshMetrics.Info
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.SchemaJob
  alias AshMetrics.Test.TenantJob

  setup do
    Ets.clear!()

    handler = "ash-metrics-runner-#{System.unique_integer([:positive])}"
    test_process = self()

    :telemetry.attach_many(
      handler,
      [
        AshMetrics.event_name(Job, :backlog),
        AshMetrics.event_name(Job, :total),
        AshMetrics.event_name(TenantJob, :backlog),
        AshMetrics.event_name(SchemaJob, :backlog)
      ],
      &__MODULE__.handle_event/4,
      %{pid: test_process}
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Ets.clear!()
    end)

    %{backlog: Info.metric!(Job, :backlog), total: Info.metric!(Job, :total)}
  end

  @doc false
  def handle_event(event, measurements, tags, %{pid: pid}) do
    send(pid, {:emitted, event, measurements, tags})

    :ok
  end

  describe "emit/3 without multitenancy" do
    test "emits one value per group and returns the groups", %{backlog: backlog} do
      seed(Job, status: :pending, provider: "ses")
      seed(Job, status: :pending, provider: "ses")
      seed(Job, status: :processing, provider: "smtp")
      seed(Job, status: :done, provider: "ses")

      assert {:ok, groups} = Runner.emit(Job, backlog)

      assert Enum.sort(groups) == [
               %{provider: "ses", status: :pending},
               %{provider: "smtp", status: :processing}
             ]

      assert emitted(Job, :backlog) == [
               {%{provider: "ses", status: :pending}, 2},
               {%{provider: "smtp", status: :processing}, 1}
             ]
    end

    test "emits a single untagged value for a gauge with no grouping", %{total: total} do
      seed(Job, status: :done)

      assert Runner.emit(Job, total) == {:ok, [%{}]}
      assert emitted(Job, :total) == [{%{}, 1}]
    end

    test "emits a zero for a gauge with no grouping and no rows", %{total: total} do
      assert Runner.emit(Job, total) == {:ok, [%{}]}
      assert emitted(Job, :total) == [{%{}, 0}]
    end

    test "emits nothing for a grouped gauge with no rows", %{backlog: backlog} do
      assert Runner.emit(Job, backlog) == {:ok, []}
      assert emitted(Job, :backlog) == []
    end
  end

  describe "emit/3 with attribute multitenancy" do
    test "emits one value per tenant in a single poll" do
      backlog = Info.metric!(TenantJob, :backlog)

      seed(TenantJob, status: :pending, org: "acme")
      seed(TenantJob, status: :processing, org: "acme")
      seed(TenantJob, status: :pending, org: "globex")
      seed(TenantJob, status: :done, org: "globex")

      assert {:ok, groups} = Runner.emit(TenantJob, backlog)

      assert Enum.sort(groups) == [
               %{status: :pending, tenant: "acme"},
               %{status: :pending, tenant: "globex"},
               %{status: :processing, tenant: "acme"}
             ]

      assert emitted(TenantJob, :backlog) == [
               {%{status: :pending, tenant: "acme"}, 1},
               {%{status: :pending, tenant: "globex"}, 1},
               {%{status: :processing, tenant: "acme"}, 1}
             ]
    end

    test "keeps the tenant attribute under its own name when it is declared" do
      backlog = %{Info.metric!(TenantJob, :backlog) | group_by: [:org]}

      seed(TenantJob, status: :pending, org: "acme")

      assert Runner.emit(TenantJob, backlog) == {:ok, [%{org: "acme", tenant: "acme"}]}
    end
  end

  describe "emit/3 with context multitenancy" do
    test "polls every tenant of the configured source and tags each emission" do
      backlog = Info.metric!(SchemaJob, :backlog)

      seed(SchemaJob, [status: :pending], "tenant_a")
      seed(SchemaJob, [status: :processing], "tenant_a")
      seed(SchemaJob, [status: :pending], "tenant_b")

      assert {:ok, groups} = Runner.emit(SchemaJob, backlog)

      assert Enum.sort(groups) == [
               %{status: :pending, tenant: "tenant_a"},
               %{status: :pending, tenant: "tenant_b"},
               %{status: :processing, tenant: "tenant_a"}
             ]

      assert emitted(SchemaJob, :backlog) == [
               {%{status: :pending, tenant: "tenant_a"}, 1},
               {%{status: :pending, tenant: "tenant_b"}, 1},
               {%{status: :processing, tenant: "tenant_a"}, 1}
             ]
    end

    test "raises when no tenant source is configured" do
      backlog = Info.metric!(SchemaJob, :backlog)
      original = Application.get_env(:ash_metrics, :tenant_source)
      Application.delete_env(:ash_metrics, :tenant_source)

      on_exit(fn -> Application.put_env(:ash_metrics, :tenant_source, original) end)

      assert_raise ArgumentError, ~r/`tenant_source` must be set/, fn ->
        Runner.emit(SchemaJob, backlog)
      end
    end
  end

  describe "emit/3 with groups that vanished" do
    test "emits a zero once for a group the poll no longer finds", %{backlog: backlog} do
      seed(Job, status: :pending, provider: "ses")
      drained = seed(Job, status: :processing, provider: "smtp")

      assert {:ok, groups} = Runner.emit(Job, backlog)
      assert length(emitted(Job, :backlog)) == 2

      Ash.destroy!(drained, authorize?: false)

      assert {:ok, current} = Runner.emit(Job, backlog, groups)

      assert current == [%{provider: "ses", status: :pending}]

      assert emitted(Job, :backlog) == [
               {%{provider: "ses", status: :pending}, 1},
               {%{provider: "smtp", status: :processing}, 0}
             ]

      assert {:ok, ^current} = Runner.emit(Job, backlog, current)

      assert emitted(Job, :backlog) == [{%{provider: "ses", status: :pending}, 1}]
    end

    test "takes the known groups as a set as well", %{backlog: backlog} do
      known = MapSet.new([%{provider: "ses", status: :pending}])

      assert Runner.emit(Job, backlog, known) == {:ok, []}
      assert emitted(Job, :backlog) == [{%{provider: "ses", status: :pending}, 0}]
    end

    test "emits a zero only once per known group", %{backlog: backlog} do
      known = [%{status: :pending}, %{status: :pending}]

      assert Runner.emit(Job, backlog, known) == {:ok, []}
      assert emitted(Job, :backlog) == [{%{status: :pending}, 0}]
    end
  end

  describe "emit/3 when the strategy fails" do
    test "returns the error and emits nothing", %{backlog: backlog} do
      assert Runner.emit(Job, %{backlog | strategy: Failing}) == {:error, :no_database}
      assert emitted(Job, :backlog) == []
    end

    test "returns the error after emitting the tenants that succeeded" do
      backlog = %{Info.metric!(SchemaJob, :backlog) | strategy: FailingForOneTenant}

      assert Runner.emit(SchemaJob, backlog) == {:error, {:unreachable, "tenant_b"}}
      assert emitted(SchemaJob, :backlog) == [{%{status: :pending, tenant: "tenant_a"}, 3}]
    end

    test "zeroes nothing when the poll failed", %{backlog: backlog} do
      failing = %{backlog | strategy: Failing}

      assert Runner.emit(Job, failing, [%{status: :pending}]) == {:error, :no_database}
      assert emitted(Job, :backlog) == []
    end
  end

  defp seed(resource, attrs, tenant \\ nil) do
    Ash.create!(resource, Map.new(attrs), authorize?: false, tenant: tenant)
  end

  # Every emission received so far, sorted, so that the order the data layer
  # happens to return groups in does not matter.
  defp emitted(resource, metric) do
    event = AshMetrics.event_name(resource, metric)

    collect(event, [])
  end

  defp collect(event, received) do
    receive do
      {:emitted, ^event, %{value: value}, tags} -> collect(event, [{tags, value} | received])
    after
      0 -> Enum.sort(received)
    end
  end
end
