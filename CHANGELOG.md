# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `c:AshMetrics.Backend.report_gauge/3`, an optional callback that takes the
  result of every successful poll of a gauge in place of the `:telemetry`
  events `AshMetrics.Gauge.Runner.emit/3` would execute. A failed poll
  reports nothing, and no group is zeroed on the backend's behalf.
- `AshMetrics.Backend.reports_gauges?/0`, which says whether the configured
  backend implements that callback.

### Changed

- `AshMetrics.Backend.Otel` exports the values the configured
  `AshMetrics.Poller` reports rather than counting a gauge when the collector
  asks for one. Its observable gauges serve the last report for twice the
  gauge's period, and the SDK exports no series for a gauge from a node that
  has not been reported to. With `AshMetrics.Poller.AshOban` the cluster
  therefore exports one series per gauge from one query per period, and with
  the timer poller one of each per node. An application selecting this
  backend must now let the pollers run.

### Removed

- `polls_gauges?/0` on `AshMetrics.Backend`, both the callback and the helper.
  `AshMetrics.child_specs/1` starts the pollers whenever polling is on,
  whatever the backend is.
- `otel_timeout/0` on `AshMetrics.Config`, and the `timeout` key of
  `config :ash_metrics, AshMetrics.Backend.Otel`, which counts nothing on
  demand any more.

## [0.2.0] - 2026-09-19

### Added

- `poll`, a runtime configuration key that keeps the gauge pollers from
  starting without changing which poller a resource compiles with. It can
  also be passed to `AshMetrics.Supervisor`. `mix ash_metrics.install` writes
  `poll: false` to `config/test.exs`.
- `mix ash_metrics.install` now prints how to select
  `AshMetrics.Poller.AshOban` when the application depends on `ash_oban`. It
  is a notice only; nothing is written to the configuration for it.
- `AshMetrics.Backend.Otel`, for an application exporting through
  OpenTelemetry with the `otel_telemetry_metrics` bridge. It drops the
  gauges' last-value definitions, which the bridge rejects, carries a
  distribution's declared buckets on as the histogram's bucket boundaries,
  and reports the gauges as OpenTelemetry observable gauges counted on
  demand, each count bounded by a configurable `timeout`. It needs the new
  optional dependency `opentelemetry_api_experimental`.
  `mix ash_metrics.install` prints how to select it when the application
  depends on the bridge.
- `polls_gauges?/0` on `AshMetrics.Backend`, an optional callback with which a
  backend declares that it reports the gauges itself. `AshMetrics.child_specs/1`
  then starts no gauge poller, whatever its `:poll` option says.
- `AshMetrics.Gauge.Runner.poll/2`, which computes one gauge's value per group
  without emitting anything. `emit/3` is unchanged.
- `AshMetrics.increment_on_write/2`, which counts every write of an attribute
  rather than every change of it, and runs atomically. The action keeps
  `require_atomic? true` and `Ash.bulk_update/4` needs no `strategy: :stream`.

### Changed

- `AshMetrics.observe_elapsed/2` now runs atomically, so an action carrying it
  no longer needs `require_atomic? false`. A `where:` whose condition reads an
  attribute still does.

## [0.1.0] - 2026-09-18

### Added

- A `metrics do` block on an Ash resource, declaring `counter`, `gauge` and
  `distribution` metrics that compile to `Telemetry.Metrics` definitions for
  the host application's own reporter. The declarations are verified while the
  resource compiles. A counter's or a distribution's tag is either open or
  closed to an enumerated set of values.
- An emission API, `AshMetrics.increment/3` and `AshMetrics.observe/4`, which
  validates the metric, the tag keys and the values of the closed tags at the
  call site.
- `AshMetrics.increment_on_change/2` and `AshMetrics.observe_elapsed/2`, two
  `Ash.Resource.Change` builders that emit a counter or a distribution from
  the action that writes the fact, after the transaction and only when it
  succeeded. Neither runs atomically, so the action needs
  `require_atomic? false`.
- Configurable metric naming, tag extraction, gauge computation and reporter
  wiring, through the `AshMetrics.NameBuilder`, `AshMetrics.TagExtractor`,
  `AshMetrics.Gauge.Strategy` and `AshMetrics.Backend` behaviours, each with a
  default implementation.
- Two gauge pollers, selectable per application or per resource:
  `AshMetrics.Poller.GenServer` on a timer, and `AshMetrics.Poller.AshOban` on
  Oban's cron. `AshMetrics.Poller` is the behaviour for anything else.
- Multitenant gauges, polled per tenant through an
  `AshMetrics.TenantSource` where Ash will not read without a tenant.
- `use AshMetrics.Test`, with `assert_metric_emitted/2` and
  `refute_metric_emitted/2`.
- `mix ash_metrics.install`, an Igniter task run as
  `mix igniter.install ash_metrics`, which writes the configuration and wires
  the metrics into the host application's reporter and supervision tree.

[Unreleased]: https://github.com/smt116/ash_metrics/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/smt116/ash_metrics/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/smt116/ash_metrics/releases/tag/v0.1.0
