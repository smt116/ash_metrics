# AshMetrics

**Status:** pre-release. Nothing is implemented yet and the package is not on Hex.
The API described below is the target, not a description of working code.

## What it is

Ash applications need declarative *business* metrics: counts and rates of business
events (emails sent, invoices captured, syncs completed), the current depth of
state-machine backlogs (how many records are `pending` right now), and latency
distributions where APM can't be trusted. Ash already emits rich `:telemetry`
events and `Telemetry.Metrics` already provides backend-agnostic metric
definitions; what is missing is a declarative layer on the resource that keeps
metric declarations next to the action they describe, validates names, tags and
outcome values at compile time, applies uniform tags without every call site
remembering them, and enforces a tag allowlist so high-cardinality values can't
leak.

AshMetrics is an Ash resource extension that adds a `metrics do` block. Those
declarations compile into a list of `Telemetry.Metrics` structs, which the host
application's existing reporter ships to whatever backend it already uses — OTLP,
StatsD, Prometheus, AppSignal. Counter emission is a synchronous
`:telemetry.execute/3`; periodic polling is only needed for gauges.

## Primitives

- **`counter`** — "How many events? How fast?" Emitted manually at the business
  moment the outcome becomes known.
- **`gauge`** — "How many right now?" Filled by a package-managed periodic poll
  over the resource.
- **`distribution`** — "What's the spread?" Observed manually, or taken off an
  Ash action's `:stop` event.

## Non-goals

- Not a new emit/aggregate/export pipeline. AshMetrics produces
  `Telemetry.Metrics` structs and lets the existing reporter ecosystem ship them.
- Not an APM or tracing tool. `ash_appsignal` and `opentelemetry_ash` cover that.
- Not a replacement for `Oban.Telemetry`, which already emits job `queue_time`
  and `duration`.

## License

MIT. See the `LICENSE` file in the repository root.
