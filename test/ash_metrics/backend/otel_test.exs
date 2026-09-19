defmodule AshMetrics.Backend.OtelTest do
  # Owns a named ETS table, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshMetrics.Backend.Otel
  alias AshMetrics.Info
  alias AshMetrics.Poller
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Job

  @period 60_000

  setup do
    %{backlog: %{Info.metric!(Job, :backlog) | period: @period}}
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

  describe "report_gauge/3" do
    setup do
      start_supervised!({Otel, gauges: []})

      :ok
    end

    test "is served by the next observation", %{backlog: backlog} do
      assert Otel.report_gauge(Job, backlog, [{%{status: :pending}, 3}]) == :ok

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]
    end

    test "replaces what the last report left", %{backlog: backlog} do
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 3}])
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 9}])

      assert Otel.observe({Job, backlog}) == [{9, %{status: :pending}}]
    end

    test "reports a group that has vanished as a zero", %{backlog: backlog} do
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 3}, {%{status: :processing}, 1}])
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 3}])

      assert Enum.sort(Otel.observe({Job, backlog})) == [
               {0, %{status: :processing}},
               {3, %{status: :pending}}
             ]
    end

    test "keeps reporting a vanished group as a zero", %{backlog: backlog} do
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 1}])
      Otel.report_gauge(Job, backlog, [])

      assert Otel.observe({Job, backlog}) == [{0, %{status: :pending}}]

      Otel.report_gauge(Job, backlog, [])

      assert Otel.observe({Job, backlog}) == [{0, %{status: :pending}}]
    end

    test "serves nothing for a first report with no groups", %{backlog: backlog} do
      Otel.report_gauge(Job, backlog, [])

      assert Otel.observe({Job, backlog}) == []
    end

    test "converts every tag value to an attribute value", %{backlog: backlog} do
      tags = %{
        status: :pending,
        provider: "ses",
        attempts: 2,
        retried: true,
        missing: nil,
        actor: %URI{host: "example.com"},
        window: {1, 2}
      }

      Otel.report_gauge(Job, backlog, [{tags, 1}])

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
  end

  describe "report_gauge/3 without the backend running" do
    test "logs an error and reports nothing", %{backlog: backlog} do
      log = capture_log(fn -> assert Otel.report_gauge(Job, backlog, []) == :ok end)

      assert log =~ "AshMetrics.Backend.Otel is not running"
      assert log =~ ":backlog"
      assert :ets.whereis(Otel) == :undefined
    end
  end

  describe "observe/1" do
    setup do
      start_supervised!({Otel, gauges: []})

      :ok
    end

    test "is empty for a gauge nothing has reported", %{backlog: backlog} do
      assert Otel.observe({Job, backlog}) == []
    end

    test "serves the last report for twice the gauge's period", %{backlog: backlog} do
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 3}])

      age(backlog, 2 * @period - 1)

      assert Otel.observe({Job, backlog}) == [{3, %{status: :pending}}]
    end

    test "is empty once twice the gauge's period has passed", %{backlog: backlog} do
      Otel.report_gauge(Job, backlog, [{%{status: :pending}, 3}])

      age(backlog, 2 * @period)

      assert Otel.observe({Job, backlog}) == []
    end
  end

  # Backdates the last report by `age` milliseconds, so that the observations
  # it left are that much older than the gauge's period.
  defp age(gauge, age) do
    [{key, reported_at, observations, known}] = :ets.lookup(Otel, {Job, gauge.name})

    :ets.insert(Otel, {key, reported_at - age, observations, known})
  end
end
