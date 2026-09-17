defmodule AshMetrics.Poller.AshObanTest do
  # Seeds a shared ETS table, so it cannot run alongside other tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test

  alias AshMetrics.Poller
  alias AshMetrics.Poller.AshOban, as: ObanPoller
  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.MarkerPoller
  alias AshMetrics.Test.ObanJob

  @action :__ash_metrics_emit_backlog__

  setup do
    Ets.clear!(ObanJob)
    on_exit(fn -> Ets.clear!(ObanJob) end)

    :ok
  end

  describe "child_specs/2" do
    test "starts nothing, because Oban's cron is what polls" do
      assert ObanPoller.child_specs([{ObanJob, :backlog}], name: :whatever) == []
    end

    test "is left out of the application's children while the others are not" do
      specs = Poller.child_specs()

      assert Enum.map(specs, & &1.id) == [AshMetrics.Poller.GenServer, MarkerPoller]

      refute Enum.any?(specs, &(&1.id == ObanPoller))
    end

    test "does not keep its gauges out of the poller's list" do
      assert {ObanJob, gauge} = Enum.find(Poller.gauges(), &match?({ObanJob, _gauge}, &1))
      assert gauge.name == :backlog
    end
  end

  describe "the generated scheduled action" do
    test "is named after the gauge and runs the generated action" do
      assert %{name: @action, action: @action} = schedule()
    end

    test "carries the cron expression for the gauge's period" do
      assert schedule().cron == "*/5 * * * *"
    end

    test "takes its queue and attempts from the configuration" do
      assert %{queue: :default, max_attempts: 1} = schedule()
    end

    test "names its worker module, so renaming cannot orphan enqueued jobs" do
      assert schedule().worker_module_name ==
               AshMetrics.Test.ObanJob.AshOban.ActionWorker.AshMetricsEmitBacklog

      assert Code.ensure_loaded?(schedule().worker)
    end

    defp schedule do
      assert [schedule] = AshOban.Info.oban_scheduled_actions(ObanJob)

      schedule
    end
  end

  describe "the generated generic action" do
    test "is private, so no API extension exposes it" do
      assert %{type: :action, public?: false} = Ash.Resource.Info.action(ObanJob, @action)
    end

    test "is run by the shared implementation, told which gauge it is" do
      assert %{run: {AshMetrics.Poller.AshOban.Emit, [gauge: :backlog]}} =
               Ash.Resource.Info.action(ObanJob, @action)
    end

    test "emits one measurement per group when it runs" do
      seed(:pending)
      seed(:pending)
      seed(:processing)

      assert Ash.run_action!(Ash.ActionInput.for_action(ObanJob, @action, %{})) == :ok

      assert_metric_emitted("test.queue.oban_job.backlog", value: 2, tags: %{status: :pending})
      assert_metric_emitted("test.queue.oban_job.backlog", value: 1, tags: %{status: :processing})
    end

    test "emits nothing at all for an empty table" do
      assert Ash.run_action!(Ash.ActionInput.for_action(ObanJob, @action, %{})) == :ok

      refute_metric_emitted("test.queue.oban_job.backlog")
    end

    test "tolerates the arguments AshOban's worker passes it" do
      input =
        Ash.ActionInput.for_action(ObanJob, @action, %{last_oban_attempt?: true},
          skip_unknown_inputs: [:last_oban_attempt?]
        )

      assert Ash.run_action!(input) == :ok
    end
  end

  describe "a gauge the poller cannot schedule" do
    test "is rejected when the resource does not use the AshOban extension" do
      error =
        Compiler.transformer_error(
          quote do
            metrics do
              poller AshMetrics.Poller.AshOban

              gauge :backlog, period: :timer.minutes(5)
            end
          end
        )

      assert %Spark.Error.DslError{} = error
      assert error.path == [:metrics, :gauge, :backlog]
      assert Exception.message(error) =~ "the `AshOban` extension"
      assert Exception.message(error) =~ "extensions: [AshOban, AshMetrics]"
    end

    test "is rejected when its period is not a whole number of minutes" do
      error =
        Compiler.transformer_error(
          quote do
            metrics do
              poller AshMetrics.Poller.AshOban

              gauge :backlog, period: :timer.seconds(90)
            end
          end,
          [AshOban, AshMetrics]
        )

      assert %Spark.Error.DslError{} = error
      assert error.path == [:metrics, :gauge, :backlog]
      assert Exception.message(error) =~ "90000ms is not a period cron can express"
      assert Exception.message(error) =~ "period: :timer.minutes(5)"
    end

    test "is left alone entirely when the resource uses another poller" do
      resource =
        Compiler.compile_resource(
          quote do
            metrics do
              gauge :backlog, period: :timer.seconds(90)
            end
          end
        )

      assert Ash.Resource.Info.action(resource, @action) == nil
    end
  end

  defp seed(status), do: Ash.create!(ObanJob, %{status: status}, authorize?: false)
end
