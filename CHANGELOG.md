# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `poll`, a runtime configuration key that keeps the gauge pollers from
  starting without changing which poller a resource compiles with. It can
  also be passed to `AshMetrics.Supervisor`. `mix ash_metrics.install` writes
  `poll: false` to `config/test.exs`.
- `mix ash_metrics.install` now prints how to select
  `AshMetrics.Poller.AshOban` when the application depends on `ash_oban`. It
  is a notice only; nothing is written to the configuration for it.

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

[Unreleased]: https://github.com/smt116/ash_metrics/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/smt116/ash_metrics/releases/tag/v0.1.0
