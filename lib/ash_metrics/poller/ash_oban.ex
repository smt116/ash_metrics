defmodule AshMetrics.Poller.AshOban do
  @moduledoc """
  Polls a resource's gauges from Oban, on a cron schedule.

  This poller runs nothing of its own: `child_specs/2` is empty, and the work
  is an Oban job like any other. Compared with the timer of
  `AshMetrics.Poller.GenServer`:

  * Oban's cron plugin inserts a single job per schedule for the whole
    cluster, so a gauge is computed once however many nodes are running.
  * A failed poll is a failed job, visible in Oban Web with its error, and
    retried if `max_attempts` allows.
  * Each gauge has its own worker module and queue entry, so its duration and
    failure rate are things Oban already measures.

  ## Choosing it

      config :ash_metrics, poller: AshMetrics.Poller.AshOban

  or, for one resource at a time:

      metrics do
        poller AshMetrics.Poller.AshOban
      end

  The schedules are generated while the resource compiles, so the
  configuration form must be in `config/config.exs`; see `AshMetrics.Config`.

  ## What the resource has to do

  1. **The resource must use the `AshOban` extension**, which owns the `oban`
     section the schedules are added to. A resource that selects this poller
     without it is a compile error naming the gauge.
  2. **Every gauge's `period` must be a whole number of minutes, hours, or
     one day**, which is all cron can express. See
     `AshMetrics.Poller.AshOban.Cron`.
  3. **The queue must exist in the host application's Oban configuration**,
     and the crontab must be the one `AshOban.config/2` built, or the
     schedules are never registered:

         config :my_app, Oban,
           AshOban.config(
             Application.fetch_env!(:my_app, :ash_domains),
             repo: MyApp.Repo,
             queues: [default: 10],
             plugins: [Oban.Plugins.Cron]
           )

  ## Configuration

      config :ash_metrics, AshMetrics.Poller.AshOban,
        queue: :default,
        max_attempts: 1

  `max_attempts` defaults to one, so a failed poll waits for its next
  schedule.

  ## What it generates

  For every gauge of a resource that selects it, a Spark transformer adds a
  private generic action `:__ash_metrics_emit_<gauge>__`, run by
  `AshMetrics.Poller.AshOban.Emit`, and a matching entry in the resource's
  `oban.scheduled_actions` with the cron expression for the gauge's period.
  Nothing should call the generated action by hand; use
  `AshMetrics.Gauge.Runner.emit/3`. The actions are not public, so extensions
  such as `ash_json_api` and `ash_graphql` do not expose them.

  ## What it does not do

  Zeroing a group that has drained means remembering the groups the previous
  poll found, and an Oban job has no state between runs.
  `AshMetrics.Poller.AshOban.Memory` holds that per node and best effort; see
  that module for the limits. A backend implementing
  `c:AshMetrics.Backend.report_gauge/3` takes the groups instead and zeroes
  vanished ones itself; the memory is not consulted then.
  """

  @behaviour AshMetrics.Poller

  alias AshMetrics.Poller

  @doc """
  No children: the polling is done by Oban's cron plugin.
  """
  @impl AshMetrics.Poller
  @spec child_specs([Poller.gauge()], keyword()) :: [Supervisor.child_spec()]
  def child_specs(_gauges, _opts \\ []), do: []
end
