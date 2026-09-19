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

defmodule AshMetrics.Gauge.RunnerTest.Reporting do
  @moduledoc false
  # A backend that takes the gauge values instead of the telemetry path. The
  # poll runs in the calling process, so the test process is its own mailbox.

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  def child_spec(_opts), do: :ignore

  @impl AshMetrics.Backend
  def report_gauge(resource, gauge, groups) do
    send(self(), {:reported, resource, gauge.name, Enum.sort(groups)})

    :ok
  end
end

defmodule AshMetrics.Gauge.RunnerTest do
  # Seeds shared ETS tables and attaches a telemetry handler, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Gauge.RunnerTest.Failing
  alias AshMetrics.Gauge.RunnerTest.FailingForOneTenant
  alias AshMetrics.Gauge.RunnerTest.Reporting
  alias AshMetrics.Info
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.GlobalTenantJob
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
        AshMetrics.event_name(GlobalTenantJob, :backlog),
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

  describe "poll/2" do
    test "returns one value per group and emits nothing", %{backlog: backlog} do
      seed(Job, status: :pending, provider: "ses")
      seed(Job, status: :pending, provider: "ses")
      seed(Job, status: :processing, provider: "smtp")

      assert {:ok, groups} = Runner.poll(Job, backlog)

      assert Enum.sort(groups) == [
               {%{provider: "ses", status: :pending}, 2},
               {%{provider: "smtp", status: :processing}, 1}
             ]

      assert emitted(Job, :backlog) == []
    end

    test "tags every tenant of a resource polled per tenant" do
      backlog = Info.metric!(SchemaJob, :backlog)

      seed(SchemaJob, [status: :pending], "tenant_a")
      seed(SchemaJob, [status: :pending], "tenant_b")

      assert {:ok, groups} = Runner.poll(SchemaJob, backlog)

      assert Enum.sort(groups) == [
               {%{status: :pending, tenant: "tenant_a"}, 1},
               {%{status: :pending, tenant: "tenant_b"}, 1}
             ]
    end

    test "returns the error of a failing strategy", %{backlog: backlog} do
      assert Runner.poll(Job, %{backlog | strategy: Failing}) == {:error, :no_database}
    end

    test "returns the error without the tenants that succeeded" do
      backlog = %{Info.metric!(SchemaJob, :backlog) | strategy: FailingForOneTenant}

      assert Runner.poll(SchemaJob, backlog) == {:error, {:unreachable, "tenant_b"}}
      assert emitted(SchemaJob, :backlog) == []
    end
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
    test "polls every tenant of the configured source, one poll each" do
      backlog = Info.metric!(TenantJob, :backlog)

      seed(TenantJob, [status: :pending], "tenant_a")
      seed(TenantJob, [status: :processing], "tenant_a")
      seed(TenantJob, [status: :pending], "tenant_b")
      seed(TenantJob, [status: :done], "tenant_b")

      assert {:ok, groups} = Runner.emit(TenantJob, backlog)

      assert Enum.sort(groups) == [
               %{status: :pending, tenant: "tenant_a"},
               %{status: :pending, tenant: "tenant_b"},
               %{status: :processing, tenant: "tenant_a"}
             ]

      assert emitted(TenantJob, :backlog) == [
               {%{status: :pending, tenant: "tenant_a"}, 1},
               {%{status: :pending, tenant: "tenant_b"}, 1},
               {%{status: :processing, tenant: "tenant_a"}, 1}
             ]
    end

    test "zeroes a group that vanished for one tenant only" do
      backlog = Info.metric!(TenantJob, :backlog)

      drained = seed(TenantJob, [status: :pending], "tenant_a")
      seed(TenantJob, [status: :pending], "tenant_b")

      assert {:ok, groups} = Runner.emit(TenantJob, backlog)
      assert length(emitted(TenantJob, :backlog)) == 2

      Ash.destroy!(drained, authorize?: false, tenant: "tenant_a")

      assert Runner.emit(TenantJob, backlog, groups) ==
               {:ok, [%{status: :pending, tenant: "tenant_b"}]}

      assert emitted(TenantJob, :backlog) == [
               {%{status: :pending, tenant: "tenant_a"}, 0},
               {%{status: :pending, tenant: "tenant_b"}, 1}
             ]
    end

    test "raises when no tenant source is configured" do
      without_tenant_source()

      assert_raise ArgumentError, ~r/`tenant_source` must be set/, fn ->
        Runner.emit(TenantJob, Info.metric!(TenantJob, :backlog))
      end
    end
  end

  describe "emit/3 with global attribute multitenancy" do
    test "emits one value per tenant in a single poll" do
      backlog = Info.metric!(GlobalTenantJob, :backlog)

      seed(GlobalTenantJob, status: :pending, org: "acme")
      seed(GlobalTenantJob, status: :processing, org: "acme")
      seed(GlobalTenantJob, status: :pending, org: "globex")
      seed(GlobalTenantJob, status: :done, org: "globex")

      assert {:ok, groups} = Runner.emit(GlobalTenantJob, backlog)

      assert Enum.sort(groups) == [
               %{status: :pending, tenant: "acme"},
               %{status: :pending, tenant: "globex"},
               %{status: :processing, tenant: "acme"}
             ]

      assert emitted(GlobalTenantJob, :backlog) == [
               {%{status: :pending, tenant: "acme"}, 1},
               {%{status: :pending, tenant: "globex"}, 1},
               {%{status: :processing, tenant: "acme"}, 1}
             ]
    end

    test "keeps the tenant attribute under its own name when it is declared" do
      backlog = %{Info.metric!(GlobalTenantJob, :backlog) | group_by: [:org]}

      seed(GlobalTenantJob, status: :pending, org: "acme")

      assert Runner.emit(GlobalTenantJob, backlog) == {:ok, [%{org: "acme", tenant: "acme"}]}
    end

    test "needs no tenant source" do
      without_tenant_source()

      seed(GlobalTenantJob, status: :pending, org: "acme")

      assert Runner.emit(GlobalTenantJob, Info.metric!(GlobalTenantJob, :backlog)) ==
               {:ok, [%{status: :pending, tenant: "acme"}]}
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
      without_tenant_source()

      assert_raise ArgumentError, ~r/`tenant_source` must be set/, fn ->
        Runner.emit(SchemaJob, Info.metric!(SchemaJob, :backlog))
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

  describe "emit/3 with a backend that takes the gauge values" do
    setup do
      original = Application.get_env(:ash_metrics, :backend)
      Application.put_env(:ash_metrics, :backend, Reporting)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:ash_metrics, :backend)
          backend -> Application.put_env(:ash_metrics, :backend, backend)
        end
      end)

      :ok
    end

    test "hands every group to the backend and emits nothing", %{backlog: backlog} do
      seed(Job, status: :pending, provider: "ses")
      seed(Job, status: :pending, provider: "ses")
      seed(Job, status: :processing, provider: "smtp")

      assert {:ok, groups} = Runner.emit(Job, backlog)

      assert Enum.sort(groups) == [
               %{provider: "ses", status: :pending},
               %{provider: "smtp", status: :processing}
             ]

      assert_received {:reported, Job, :backlog,
                       [
                         {%{provider: "ses", status: :pending}, 2},
                         {%{provider: "smtp", status: :processing}, 1}
                       ]}

      assert emitted(Job, :backlog) == []
    end

    test "reports an empty poll rather than zeroing a vanished group", %{backlog: backlog} do
      known = [%{provider: "ses", status: :pending}]

      assert Runner.emit(Job, backlog, known) == {:ok, []}

      assert_received {:reported, Job, :backlog, []}
      assert emitted(Job, :backlog) == []
    end

    test "reports nothing when the strategy fails", %{backlog: backlog} do
      failing = %{backlog | strategy: Failing}

      assert Runner.emit(Job, failing) == {:error, :no_database}

      refute_received {:reported, _resource, _name, _groups}
      assert emitted(Job, :backlog) == []
    end

    test "reports nothing when the strategy fails for one tenant only" do
      backlog = %{Info.metric!(SchemaJob, :backlog) | strategy: FailingForOneTenant}

      assert Runner.emit(SchemaJob, backlog) == {:error, {:unreachable, "tenant_b"}}

      refute_received {:reported, _resource, _name, _groups}
      assert emitted(SchemaJob, :backlog) == []
    end
  end

  defp seed(resource, attrs, tenant \\ nil) do
    Ash.create!(resource, Map.new(attrs), authorize?: false, tenant: tenant)
  end

  defp without_tenant_source do
    original = Application.get_env(:ash_metrics, :tenant_source)
    Application.delete_env(:ash_metrics, :tenant_source)

    on_exit(fn -> Application.put_env(:ash_metrics, :tenant_source, original) end)
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
