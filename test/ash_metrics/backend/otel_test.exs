defmodule AshMetrics.Backend.OtelTest.Strategy do
  @moduledoc false
  # A strategy answering with canned results in order, the last one repeating.

  @behaviour AshMetrics.Gauge.Strategy

  def start_link(results), do: Agent.start_link(fn -> results end, name: __MODULE__)

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts) do
    Agent.get_and_update(__MODULE__, fn
      [last] -> {last, [last]}
      [result | rest] -> {result, rest}
    end)
  end
end

defmodule AshMetrics.Backend.OtelTest.Sleeping do
  @moduledoc false
  # A strategy that never answers, to prove the timeout.

  @behaviour AshMetrics.Gauge.Strategy

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts), do: Process.sleep(:infinity)
end

defmodule AshMetrics.Backend.OtelTest.Raising do
  @moduledoc false
  # A strategy that raises, to prove the callback survives one.

  @behaviour AshMetrics.Gauge.Strategy

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts), do: raise("no database")
end

defmodule AshMetrics.Backend.OtelTest do
  # Owns a named ETS table and a named agent, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshMetrics.Backend.Otel
  alias AshMetrics.Backend.OtelTest.Raising
  alias AshMetrics.Backend.OtelTest.Sleeping
  alias AshMetrics.Backend.OtelTest.Strategy
  alias AshMetrics.Info
  alias AshMetrics.Poller
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Job

  @period 60_000

  setup do
    original = Application.get_env(:ash_metrics, Otel)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, Otel)
        value -> Application.put_env(:ash_metrics, Otel, value)
      end
    end)

    %{backlog: %{Info.metric!(Job, :backlog) | strategy: Strategy, period: @period}}
  end

  describe "transform_metrics/2" do
    test "drops every last value" do
      metrics = Otel.transform_metrics(AshMetrics.metrics_for([Job]), [])

      refute Enum.any?(metrics, &match?(%Telemetry.Metrics.LastValue{}, &1))
      assert metrics == []
    end

    test "leaves a counter alone" do
      counter = Telemetry.Metrics.counter("test.invoice.issued.count")

      assert Otel.transform_metrics([counter], []) == [counter]
    end

    test "carries a distribution's buckets on as bucket boundaries" do
      distribution =
        Telemetry.Metrics.distribution("test.invoice.settled.duration",
          reporter_options: [buckets: [10, 100, 1000]]
        )

      assert [%Telemetry.Metrics.Distribution{} = transformed] =
               Otel.transform_metrics([distribution], [])

      assert Keyword.fetch!(transformed.reporter_options, :otel) == %{
               advisory_params: %{explicit_bucket_boundaries: [10, 100, 1000]}
             }

      assert Keyword.fetch!(transformed.reporter_options, :buckets) == [10, 100, 1000]
    end

    test "leaves a distribution without buckets alone" do
      distribution = Telemetry.Metrics.distribution("test.invoice.settled.duration")

      assert Otel.transform_metrics([distribution], []) == [distribution]
    end

    test "merges into an existing otel map" do
      distribution =
        Telemetry.Metrics.distribution("test.invoice.settled.duration",
          reporter_options: [
            buckets: [1, 2],
            otel: %{unit: "ms", advisory_params: %{something_else: true}}
          ]
        )

      assert [transformed] = Otel.transform_metrics([distribution], [])

      assert Keyword.fetch!(transformed.reporter_options, :otel) == %{
               unit: "ms",
               advisory_params: %{something_else: true, explicit_bucket_boundaries: [1, 2]}
             }
    end

    test "is applied to the compiled definitions" do
      Application.put_env(:ash_metrics, :backend, Otel)
      on_exit(fn -> Application.delete_env(:ash_metrics, :backend) end)

      names = Enum.map(AshMetrics.metrics_for([Invoice, Job]), & &1.name)

      refute Enum.any?(names, &(List.last(&1) == :gauge))
      assert names != []
    end
  end

  describe "polls_gauges?/0" do
    test "is true" do
      assert Otel.polls_gauges?()
    end
  end

  describe "child_spec/1" do
    test "registers every declared gauge against the noop meter" do
      start_supervised!({Otel, gauges: Poller.gauges()})

      assert length(:ets.tab2list(Otel)) == length(Poller.gauges())
      assert Poller.gauges() != []
    end

    test "starts a process a supervisor accepts" do
      assert %{id: Otel, start: {Otel, :start_link, [[gauges: []]]}} =
               Otel.child_spec(gauges: [])

      pid = start_supervised!({Otel, gauges: [], name: :ash_metrics_otel})

      assert Process.alive?(pid)
      assert Process.whereis(:ash_metrics_otel) == pid
    end
  end

  describe "observe/1" do
    setup do
      start_supervised!({Otel, gauges: []})

      :ok
    end

    test "counts the gauge and returns one observation per group", %{backlog: backlog} do
      canned([{:ok, [{%{status: :pending}, 3}, {%{status: :processing}, 1}]}])

      assert Enum.sort(Otel.observe({Job, backlog})) == [
               {1, %{status: :processing}},
               {3, %{status: :pending}}
             ]
    end

    test "serves the last count within the gauge's period", %{backlog: backlog} do
      canned([{:ok, [{%{status: :pending}, 3}]}, {:ok, [{%{status: :pending}, 9}]}])

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]
      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]
    end

    test "counts again once the period has passed", %{backlog: backlog} do
      canned([{:ok, [{%{status: :pending}, 3}]}, {:ok, [{%{status: :pending}, 9}]}])

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]

      age(backlog, @period)

      assert Otel.observe({Job, backlog}) == [{9, %{status: :pending}}]
    end

    test "reports a group that has vanished as a zero", %{backlog: backlog} do
      canned([
        {:ok, [{%{status: :pending}, 3}, {%{status: :processing}, 1}]},
        {:ok, [{%{status: :pending}, 3}]}
      ])

      assert length(Otel.observe({Job, backlog})) == 2

      age(backlog, @period)

      assert Enum.sort(Otel.observe({Job, backlog})) == [
               {0, %{status: :processing}},
               {3, %{status: :pending}}
             ]
    end

    test "keeps reporting a vanished group as a zero", %{backlog: backlog} do
      canned([{:ok, [{%{status: :pending}, 1}]}, {:ok, []}])

      assert Otel.observe({Job, backlog}) == [{1, %{status: :pending}}]

      age(backlog, @period)
      assert Otel.observe({Job, backlog}) == [{0, %{status: :pending}}]

      age(backlog, @period)
      assert Otel.observe({Job, backlog}) == [{0, %{status: :pending}}]
    end

    test "returns nothing for a first count with no groups", %{backlog: backlog} do
      canned([{:ok, []}])

      assert Otel.observe({Job, backlog}) == []
    end

    test "converts every tag value to an attribute value", %{backlog: backlog} do
      canned([
        {:ok,
         [
           {%{
              status: :pending,
              provider: "ses",
              attempts: 2,
              retried: true,
              missing: nil,
              actor: %URI{host: "example.com"},
              window: {1, 2}
            }, 1}
         ]}
      ])

      assert [{1, attributes}] = Otel.observe({Job, backlog})

      assert attributes == %{
               status: :pending,
               provider: "ses",
               attempts: 2,
               retried: true,
               missing: nil,
               window: "{1, 2}"
             }
    end

    test "keeps the previous observations when the count fails", %{backlog: backlog} do
      canned([{:ok, [{%{status: :pending}, 3}]}, {:error, :no_database}])

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]

      age(backlog, @period)

      log =
        capture_log(fn -> assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}] end)

      assert log =~ "could not count the gauge :backlog"
      assert log =~ ":no_database"
    end

    test "keeps the previous observations when the count raises", %{backlog: backlog} do
      canned([{:ok, [{%{status: :pending}, 3}]}])

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]

      raising = %{backlog | strategy: Raising}
      age(backlog, @period)

      log =
        capture_log(fn -> assert Otel.observe({Job, raising}) == [{3, %{status: :pending}}] end)

      assert log =~ "no database"
    end

    test "keeps the previous observations when the count overruns the timeout", %{
      backlog: backlog
    } do
      Application.put_env(:ash_metrics, Otel, timeout: 50)
      canned([{:ok, [{%{status: :pending}, 3}]}])

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]

      sleeping = %{backlog | strategy: Sleeping}
      age(backlog, @period)

      log =
        capture_log(fn -> assert Otel.observe({Job, sleeping}) == [{3, %{status: :pending}}] end)

      assert log =~ "{:timeout, 50}"
    end

    test "counts again after a failure", %{backlog: backlog} do
      canned([{:error, :no_database}, {:ok, [{%{status: :pending}, 3}]}])

      assert capture_log(fn -> assert Otel.observe({Job, backlog}) == [] end) =~ ":no_database"
      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]
    end
  end

  defp canned(results) do
    start_supervised!(%{id: Strategy, start: {Strategy, :start_link, [results]}})
  end

  # Backdates the last count by `age` milliseconds, so that the next
  # observation counts again rather than serving it.
  defp age(gauge, age) do
    [{key, counted_at, observations, known}] = :ets.lookup(Otel, {Job, gauge.name})

    :ets.insert(Otel, {key, counted_at - age, observations, known})
  end
end
