<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Pollers and backends

A poller decides when a gauge is computed. A backend decides what happens to
the metric definitions and to the values a poll produces. They are
independent choices.

## Pollers

`AshMetrics.Poller.GenServer` is the default and needs no configuration: one
process per node holding one timer per gauge, first poll at startup. Every
node polls, so a five-node cluster computes and emits each gauge five times
per period.

`AshMetrics.Poller.AshOban` polls from Oban's cron instead — one job per
period for the whole cluster, a failed poll visible as a failed Oban job.
Select it for the application in compile-time configuration, or per resource:

```elixir
# config/config.exs — read while resources compile.
config :ash_metrics, poller: AshMetrics.Poller.AshOban
```

```elixir
metrics do
  poller AshMetrics.Poller.AshOban

  gauge :backlog, filter: expr(status == :pending), period: :timer.minutes(5)
end
```

A resource that selects it must:

1. use the `AshOban` extension;
2. declare every gauge `period:` as a whole number of minutes (1 to 59),
   hours (1 to 23), or exactly one day — the only periods cron expresses
   exactly;
3. have its queue in the host application's Oban configuration, and that
   configuration built with `AshOban.config/2` with `Oban.Plugins.Cron`
   enabled, or the schedules are never registered.

The first two are compile errors naming the gauge. The third is not checked:
an unregistered schedule simply never fires, and the gauge reports nothing.

Per gauge the transformer generates a private generic action named
`__ash_metrics_emit_<gauge>__` and a matching entry in the resource's
`oban.scheduled_actions`. Never call that action by hand — use
`AshMetrics.Gauge.Runner.emit/3`.

`poll: false` in runtime configuration starts no poller process. It does not
stop `AshMetrics.Poller.AshOban`, which runs no process of its own.

## Backends

`AshMetrics.Backend.Noop` is the default and the normal case: the host
application already runs a reporter and only splices `AshMetrics.metrics/0`
into the metric list it hands it. The backend starts nothing.

`AshMetrics.Backend.Otel` is for an application exporting through
OpenTelemetry with the `otel_telemetry_metrics` bridge. Select it with
`config :ash_metrics, backend: AshMetrics.Backend.Otel` and keep splicing
`AshMetrics.metrics/0` into your own bridge instance. It:

- requires the pollers to run — it exports the values they report, and
  nothing else produces them;
- drops every last-value definition from the compiled list, because the
  bridge rejects them, and exports each gauge as an OpenTelemetry observable
  gauge instead;
- serves the last report from the node that polled, for twice that gauge's
  `period:`;
- carries the exporting node's resource attributes on every series, so
  aggregate over `host` when querying a gauge across nodes.

Pair it with `AshMetrics.Poller.AshOban` to get one series per gauge for the
whole cluster. With the timer poller every node exports its own.

A custom backend implements the `AshMetrics.Backend` behaviour. Implementing
`c:AshMetrics.Backend.report_gauge/3` diverts every successful poll to the
backend: no `:telemetry` event is executed for that gauge, and zeroing a
group that has vanished since the last report becomes the backend's job.

## Starting them

Add `AshMetrics.Supervisor` to the supervision tree after the repository — a
gauge is answered by a query. It supervises the backend's children followed
by every poller in use. `AshMetrics.child_specs/1` returns the same list for
a tree that would rather splice children in than add a supervisor.

```elixir
children = [
  MyApp.Repo,
  {Telemetry.Metrics.ConsoleReporter, metrics: my_own_metrics() ++ AshMetrics.metrics()},
  AshMetrics.Supervisor
]
```
