defmodule AshMetrics.Integration.AshObanPollerPostgresTest do
  # Starts a real Oban instance against a shared database, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.PgObanJob]

  @moduletag :postgres

  alias AshMetrics.Poller.AshOban.Memory
  alias AshMetrics.Test.Pg
  alias AshMetrics.Test.PgObanJob
  alias AshMetrics.Test.Repo

  @queue :default
  @metric "test.pg.pg_oban_job.backlog"

  setup do
    Repo.delete_all(PgObanJob)
    Repo.delete_all(Oban.Job)
    Memory.clear(PgObanJob, :backlog)

    on_exit(fn ->
      Repo.delete_all(PgObanJob)
      Repo.delete_all(Oban.Job)
      Memory.clear(PgObanJob, :backlog)
    end)

    %{config: config()}
  end

  describe "AshOban.config/2" do
    test "registers the generated schedule in the crontab", %{config: config} do
      assert {"* * * * *", worker, _opts} = Enum.find(crontab(config), &(elem(&1, 1) == worker()))
      assert worker == worker()
    end

    test "leaves the resources with no Oban poller out of the crontab", %{config: config} do
      assert length(crontab(config)) == 1
    end
  end

  describe "a drained queue" do
    setup %{config: config} do
      start_supervised!({Oban, Keyword.put(config, :testing, :manual)})

      :ok
    end

    test "runs the poll and emits one measurement per group" do
      seed(:pending)
      seed(:pending)
      seed(:processing)

      assert %{success: 1, failure: 0} = drain()

      assert_metric_emitted(@metric, value: 2, tags: %{status: :pending})
      assert_metric_emitted(@metric, value: 1, tags: %{status: :processing})
    end

    test "leaves the job completed" do
      seed(:pending)

      drain()

      assert [%Oban.Job{state: "completed", worker: worker}] = Repo.all(Oban.Job)
      assert worker == inspect(worker())
    end

    test "zeroes a group that drained between two runs" do
      seed(:pending)

      drain()
      assert_metric_emitted(@metric, value: 1, tags: %{status: :pending})
      assert Memory.get(PgObanJob, :backlog) == [%{status: :pending}]

      Repo.delete_all(PgObanJob)

      drain()
      assert_metric_emitted(@metric, value: 0, tags: %{status: :pending})
      assert Memory.get(PgObanJob, :backlog) == []
    end
  end

  defp config do
    AshOban.config([Pg],
      repo: Repo,
      queues: [{@queue, 5}],
      plugins: [Oban.Plugins.Cron],
      notifier: Oban.Notifiers.Isolated
    )
  end

  defp crontab(config) do
    {Oban.Plugins.Cron, opts} = Enum.find(config[:plugins], &match?({Oban.Plugins.Cron, _}, &1))

    opts[:crontab]
  end

  defp worker do
    [schedule] = AshOban.Info.oban_scheduled_actions(PgObanJob)

    schedule.worker
  end

  # The crontab plugin does not run under `testing: :manual`, so the job it
  # would have inserted is inserted by hand and the queue drained on demand.
  defp drain do
    worker().new(%{}) |> Oban.insert!()

    Oban.drain_queue(queue: @queue)
  end

  defp seed(status), do: Ash.create!(PgObanJob, %{status: status}, authorize?: false)
end
