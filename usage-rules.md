<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Rules for working with AshMetrics

## Understanding AshMetrics

AshMetrics is an Ash resource extension that adds a `metrics do` block in
which counters, gauges and distributions are declared, and compiles those
declarations into `Telemetry.Metrics` definitions for the reporter the host
application already runs.

Read `documentation/dsls/DSL-AshMetrics.md` before declaring metrics. It is
generated from the DSL and lists every entity and every option.

Apply the design test before adding anything to this package: would this
work, unmodified, for a single-tenant Phoenix app exporting to Prometheus,
with no Oban and no OpenTelemetry? If the answer is no, something
app-specific has leaked in.

## Topics

- `usage-rules/declaring_metrics.md` — the three primitives, tags and metric
  names.
- `usage-rules/emitting.md` — which change or function emits a counter or a
  distribution.
- `usage-rules/gauges.md` — filtering, grouping, cost and multitenancy.
- `usage-rules/pollers_and_backends.md` — who polls a gauge, and where the
  value goes.
- `usage-rules/configuration.md` — every configuration key, and when it is
  read.
- `usage-rules/testing.md` — asserting on emissions.
