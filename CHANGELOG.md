# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `AshMetrics`, an `Ash.Resource` extension adding a `metrics do` block with
  `counter`, `gauge` and `distribution` declarations.
- Compile-time verification of the declarations: a configured `prefix`, unique
  metric names, non-empty unique outcomes, unique tag keys that do not collide
  with reserved ones, strictly ascending positive buckets, gauges grouping by
  attributes of their resource, and a configured `tenant_source` for a
  resource declaring a gauge that has to be polled per tenant.
- `AshMetrics.increment/3` and `AshMetrics.observe/4`, which validate the
  metric, outcome and tag keys at the call site before emitting.
- `AshMetrics.metrics/0` and `AshMetrics.metrics_for/1`, which compile the
  declarations into `Telemetry.Metrics` definitions for a host application's
  reporter.
- `AshMetrics.Info` for introspection, and `AshMetrics.Config` for the
  `:ash_metrics` application environment.
- `AshMetrics.NameBuilder` and `AshMetrics.TagExtractor` behaviours, with
  `AshMetrics.NameBuilder.Default` and `AshMetrics.TagExtractor.Default`.
- `AshMetrics.Gauge.Strategy` behaviour, with `AshMetrics.Gauge.Strategy.Count`,
  which counts each group exactly.
- `AshMetrics.TenantSource` behaviour, for enumerating the tenants of a
  resource whose gauges are polled once per tenant.
- `AshMetrics.Gauge.Runner`, which polls one gauge, emits one value per group
  and per tenant, and emits a single zero for a group that has vanished.
- `AshMetrics.Poller` behaviour, with `AshMetrics.Poller.GenServer`, which
  polls every gauge from one process on a timer per gauge and survives a
  failing or raising strategy.
- `AshMetrics.child_specs/1`, the backend's children followed by the poller's.
- `AshMetrics.Backend` behaviour, with `AshMetrics.Backend.Noop` and
  `AshMetrics.Backend.Test`.
- `use AshMetrics.Test`, with `assert_metric_emitted/2` and
  `refute_metric_emitted/2`.
