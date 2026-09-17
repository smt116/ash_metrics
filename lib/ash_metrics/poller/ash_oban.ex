defmodule AshMetrics.Poller.AshOban do
  @moduledoc """
  Polls a resource's gauges from Oban, on a cron schedule.

  Where `AshMetrics.Poller.GenServer` runs a timer on every node, this poller
  runs nothing of its own: `child_specs/2` is empty, and the work is an Oban
  job like any other. That buys three things a timer cannot.

  * **One poll per period, not one per node.** Oban's cron plugin inserts a
    single job per schedule for the whole cluster, so a gauge is computed once
    however many nodes are running.
  * **A failed poll is a failed job.** It appears in Oban Web with its error,
    and is retried if `max_attempts` says so, rather than disappearing into a
    log line.
  * **The poll is visible.** Each gauge has its own worker module and its own
    queue entry, so how long polling takes and how often it fails are
    questions Oban already answers.

  ## Choosing it

      config :ash_metrics, poller: AshMetrics.Poller.AshOban

  or, for one resource at a time:

      metrics do
        poller AshMetrics.Poller.AshOban
      end

  ## What the resource has to do

  The generated machinery is invisible, but it is not free of requirements.

  1. **The resource must use the `AshOban` extension**, because that is what
     owns the `oban` section the schedules are added to. A resource that
     selects this poller without it is a compile error naming the gauge.
  2. **Every gauge's `period` must be a whole number of minutes, hours, or
     one day.** Cron cannot express anything else, and rounding silently
     would make the declaration a lie. See
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

  `max_attempts` defaults to one on purpose. A gauge answers a question about
  the present, so retrying a poll that failed three minutes ago answers a
  different question than the one that failed; the next scheduled poll is the
  better retry.

  ## What it generates

  For every gauge of a resource that selects it, a Spark transformer adds a
  private generic action `:__ash_metrics_emit_<gauge>__`, run by
  `AshMetrics.Poller.AshOban.Emit`, and a matching entry in the resource's
  `oban.scheduled_actions` with the cron expression for the gauge's period.
  The names are prefixed and suffixed with underscores to signal that nothing
  should call them by hand, and the actions are not public, so extensions such
  as `ash_json_api` and `ash_graphql` do not expose them.

  ## What it does not do

  A `last_value` gauge has to be told when a group has drained, which means
  remembering the groups the previous poll found. A timer keeps that in the
  poller's own process state; an Oban job has no state at all between runs, so
  `AshMetrics.Poller.AshOban.Memory` keeps it in `:persistent_term` — per
  node, best effort. See that module for what that costs.
  """

  @behaviour AshMetrics.Poller

  alias AshMetrics.Poller

  @doc """
  No children: the polling is done by Oban's cron plugin.

  The gauges are still handed over, as they are to every poller, and still
  ignored. `AshMetrics.child_specs/1` therefore remains the one call a host
  application makes whichever poller it chose.
  """
  @impl AshMetrics.Poller
  @spec child_specs([Poller.gauge()], keyword()) :: [Supervisor.child_spec()]
  def child_specs(_gauges, _opts \\ []), do: []
end
