defmodule AshMetrics.AssertionsTest do
  # Attaches handlers for globally visible `:telemetry` events.
  use ExUnit.Case, async: false
  use AshMetrics.Test

  alias AshMetrics.Backend
  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Info
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Job

  @delivery "test.mailings.templated_delivery.delivery"
  @send_latency "test.mailings.templated_delivery.send_latency"
  @capture "test.mailings.invoice.capture"
  @backlog "test.queue.job.backlog"

  describe "AshMetrics.Backend.Test" do
    test "starts nothing" do
      assert Backend.Test.child_spec([]) == :ignore
    end

    test "detaching when nothing is attached is not an error" do
      assert Backend.Test.detach(spawn(fn -> :ok end)) == :ok
    end
  end

  describe "assert_metric_emitted/2" do
    test "matches a counter by name" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent)

      assert assert_metric_emitted(@delivery) == {%{count: 1}, %{outcome: :sent}}
    end

    test "matches a counter by outcome" do
      AshMetrics.increment(Delivery, :delivery, outcome: :bounced, tags: %{provider: "ses"})

      assert {measurements, tags} = assert_metric_emitted(@delivery, outcome: :bounced)
      assert measurements == %{count: 1}
      assert tags == %{outcome: :bounced, provider: "ses"}
    end

    test "matches tags as a subset" do
      AshMetrics.increment(Delivery, :delivery,
        outcome: :sent,
        tags: %{provider: "ses", template: "welcome"}
      )

      assert_metric_emitted(@delivery, outcome: :sent, tags: %{provider: "ses"})
    end

    test "matches a distribution by value" do
      AshMetrics.observe(Delivery, :send_latency, 142, tags: %{provider: "ses"})

      assert {%{value: 142}, %{provider: "ses"}} =
               assert_metric_emitted(@send_latency, value: 142, tags: %{provider: "ses"})
    end

    test "leaves emissions of other metrics in the mailbox" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent)
      AshMetrics.increment(Invoice, :capture, outcome: :succeeded)
      AshMetrics.observe(Delivery, :send_latency, 7)

      assert_metric_emitted(@capture, outcome: :succeeded)
      assert_metric_emitted(@send_latency, value: 7)
      assert_metric_emitted(@delivery, outcome: :sent)
    end

    test "leaves same-name emissions that did not match in the mailbox" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent)
      AshMetrics.increment(Delivery, :delivery, outcome: :bounced)

      assert_metric_emitted(@delivery, outcome: :bounced)
      assert_metric_emitted(@delivery, outcome: :sent)
    end

    test "fails naming the expectation and the emissions of that name received" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent, tags: %{provider: "ses"})

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_metric_emitted(@delivery, outcome: :bounced, timeout: 1)
        end

      assert error.message =~ "Expected #{inspect(@delivery)} to be emitted with outcome :bounced"
      assert error.message =~ "Emissions of that name that were received:"
      assert error.message =~ ~s(tags %{provider: "ses", outcome: :sent})
    end

    test "fails saying nothing of that name arrived when nothing did" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_metric_emitted(@delivery, timeout: 1)
        end

      assert error.message =~ "No emission of that name was received."
    end

    test "waits for an emission from another process" do
      test_process = self()

      spawn(fn ->
        send(test_process, :go)
        Process.sleep(10)
        send(test_process, {:ash_metrics, @capture, %{count: 1}, %{outcome: :failed}})
      end)

      assert_receive :go

      assert {%{count: 1}, %{outcome: :failed}} =
               assert_metric_emitted(@capture, outcome: :failed)
    end
  end

  describe "a polled gauge" do
    setup do
      Ets.clear!()
      on_exit(&Ets.clear!/0)

      :ok
    end

    test "is matched by name, with the group as its tags" do
      Ash.create!(Job, %{status: :pending, provider: "ses"}, authorize?: false)
      Ash.create!(Job, %{status: :pending, provider: "ses"}, authorize?: false)

      Runner.emit(Job, Info.metric!(Job, :backlog))

      assert assert_metric_emitted(@backlog, value: 2) ==
               {%{value: 2}, %{provider: "ses", status: :pending}}
    end

    test "is matched when it is zeroed after its group vanished" do
      Runner.emit(Job, Info.metric!(Job, :backlog), [%{provider: "ses", status: :pending}])

      assert_metric_emitted(@backlog, value: 0, tags: %{provider: "ses"})
    end
  end

  describe "refute_metric_emitted/2" do
    test "passes when the metric was not emitted" do
      assert refute_metric_emitted(@delivery) == :ok
    end

    test "passes when the metric was emitted with a different outcome" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent)

      assert refute_metric_emitted(@delivery, outcome: :bounced) == :ok
    end

    test "leaves the emission it refused to match in the mailbox" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent)

      refute_metric_emitted(@delivery, outcome: :bounced)

      assert_metric_emitted(@delivery, outcome: :sent)
    end

    test "fails showing the emission when the metric was emitted" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent, tags: %{provider: "ses"})

      error =
        assert_raise ExUnit.AssertionError, fn ->
          refute_metric_emitted(@delivery, outcome: :sent)
        end

      assert error.message =~
               "Expected #{inspect(@delivery)} not to be emitted with outcome :sent, but it was."

      assert error.message =~ "Measurements: %{count: 1}"
      assert error.message =~ ~s(Tags: %{provider: "ses", outcome: :sent})
    end
  end
end
