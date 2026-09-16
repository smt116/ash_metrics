defmodule AshMetrics.Poller.GenServerTest.Notify do
  @moduledoc false
  # Tells the listening test process that a strategy ran. A strategy that
  # neither emits nor returns groups is otherwise invisible, and counting
  # polls by waiting for a number of milliseconds is a coin toss.

  @name :ash_metrics_poller_gen_server_test

  @spec listen() :: true
  def listen, do: Process.register(self(), @name)

  @spec polled(module()) :: :ok
  def polled(strategy) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> send(pid, {:polled, strategy})
    end

    :ok
  end
end

defmodule AshMetrics.Poller.GenServerTest.Raising do
  @moduledoc false
  # A strategy that raises, which a poller has to survive.

  @behaviour AshMetrics.Gauge.Strategy

  alias AshMetrics.Poller.GenServerTest.Notify

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts) do
    Notify.polled(__MODULE__)

    raise "the database is on fire"
  end
end

defmodule AshMetrics.Poller.GenServerTest.Failing do
  @moduledoc false
  # A strategy that fails without raising.

  @behaviour AshMetrics.Gauge.Strategy

  alias AshMetrics.Poller.GenServerTest.Notify

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts) do
    Notify.polled(__MODULE__)

    {:error, :no_database}
  end
end

defmodule AshMetrics.Poller.GenServerTest do
  # Seeds shared ETS tables and attaches a telemetry handler, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshMetrics.Info
  alias AshMetrics.Poller.GenServer, as: Poller
  alias AshMetrics.Poller.GenServerTest.Failing
  alias AshMetrics.Poller.GenServerTest.Notify
  alias AshMetrics.Poller.GenServerTest.Raising
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Job

  @period 30

  setup do
    Ets.clear!()
    Notify.listen()

    handler = "ash-metrics-poller-#{System.unique_integer([:positive])}"
    test_process = self()

    :telemetry.attach_many(
      handler,
      [AshMetrics.event_name(Job, :backlog), AshMetrics.event_name(Job, :total)],
      &__MODULE__.handle_event/4,
      %{pid: test_process}
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Ets.clear!()
    end)

    %{backlog: gauge(:backlog), total: gauge(:total)}
  end

  @doc false
  def handle_event([_ash_metrics, _resource, metric], measurements, tags, %{pid: pid}) do
    send(pid, {:emitted, metric, measurements, tags})

    :ok
  end

  test "polls a gauge immediately and again every period", %{total: total} do
    seed(status: :pending)

    start!([{Job, total}])

    assert_receive {:emitted, :total, %{value: 1}, %{}}, 200
    assert_receive {:emitted, :total, %{value: 1}, %{}}, 200
    assert_receive {:emitted, :total, %{value: 1}, %{}}, 200
  end

  test "polls every gauge it was given", %{backlog: backlog, total: total} do
    seed(status: :pending, provider: "ses")

    start!([{Job, backlog}, {Job, total}])

    assert_receive {:emitted, :backlog, %{value: 1}, %{provider: "ses", status: :pending}}, 200
    assert_receive {:emitted, :total, %{value: 1}, %{}}, 200
  end

  test "zeroes a group that vanished between two polls", %{backlog: backlog} do
    drained = seed(status: :pending, provider: "ses")

    start!([{Job, backlog}])

    assert_receive {:emitted, :backlog, %{value: 1}, _tags}, 200

    Ash.destroy!(drained, authorize?: false)

    assert_receive {:emitted, :backlog, %{value: 0}, %{provider: "ses", status: :pending}}, 200
  end

  test "logs a strategy that fails and keeps polling", %{backlog: backlog} do
    log =
      capture_log(fn ->
        poller = start!([{Job, %{backlog | strategy: Failing}}])

        assert_receive {:polled, Failing}, 200
        assert_receive {:polled, Failing}, 200
        assert Process.alive?(poller)
      end)

    assert log =~ "AshMetrics could not poll the gauge :backlog on AshMetrics.Test.Job"
    assert log =~ ":no_database"
    assert log =~ "polled again in #{@period}ms"
  end

  test "logs a strategy that raises and keeps polling the others", %{
    backlog: backlog,
    total: total
  } do
    seed(status: :pending)

    log =
      capture_log(fn ->
        poller = start!([{Job, %{backlog | strategy: Raising}}, {Job, total}])

        assert_receive {:polled, Raising}, 200
        assert_receive {:polled, Raising}, 200
        assert_receive {:emitted, :total, %{value: 1}, %{}}, 200
        assert Process.alive?(poller)
      end)

    assert log =~ "AshMetrics could not poll the gauge :backlog on AshMetrics.Test.Job"
    assert log =~ "the database is on fire"
    refute_received {:emitted, :backlog, _measurements, _tags}
  end

  test "can be started under a name", %{total: total} do
    name = :"poller-#{System.unique_integer([:positive])}"

    start!([{Job, total}], name: name)

    assert is_pid(Process.whereis(name))
  end

  describe "child_specs/2" do
    test "is one process for every gauge", %{backlog: backlog, total: total} do
      gauges = [{Job, backlog}, {Job, total}]

      assert [%{id: Poller, start: {Poller, :start_link, [[gauges: ^gauges]]}}] =
               Poller.child_specs(gauges)
    end

    test "passes its options on", %{total: total} do
      assert [%{start: {Poller, :start_link, [args]}}] =
               Poller.child_specs([{Job, total}], name: :polling)

      assert Keyword.fetch!(args, :name) == :polling
    end
  end

  # Every gauge is polled far faster than it is declared, so that a test can
  # watch several polls of it without waiting a minute.
  defp gauge(name), do: %{Info.metric!(Job, name) | period: @period}

  defp seed(attrs), do: Ash.create!(Job, Map.new(attrs), authorize?: false)

  defp start!(gauges, opts \\ []) do
    [spec] = Poller.child_specs(gauges, opts)

    start_supervised!(spec)
  end
end
