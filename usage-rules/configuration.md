<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Configuration

```elixir
config :ash_metrics,
  prefix: "myapp",                                  # REQUIRED
  otp_app: :my_app,                                 # REQUIRED
  name_builder: AshMetrics.NameBuilder.Default,
  tag_extractor: AshMetrics.TagExtractor.Default,
  backend: AshMetrics.Backend.Noop,
  poller: AshMetrics.Poller.GenServer,
  poll: true,
  tenant_source: MyApp.Tenants                      # per-tenant gauges only

# Only when the Oban poller is selected.
config :ash_metrics, AshMetrics.Poller.AshOban,
  queue: :default,
  max_attempts: 1
```

## When each key is read

Put the compile-time keys in `config/config.exs`. `config/runtime.exs` alone
is too late for them.

| Key | Read |
| --- | --- |
| `prefix:` | compile time — a verifier rejects a resource declaring metrics without it |
| `poller:` | compile time — it decides whether Oban schedules are generated |
| `otp_app:` | runtime, on every call |
| `name_builder:` | runtime, on every call |
| `tag_extractor:` | runtime, on every call |
| `backend:` | runtime, on every call |
| `poll:` | runtime, when the children are built |
| `tenant_source:` | runtime, on every poll of a per-tenant gauge |
| `queue` and `max_attempts` under `AshMetrics.Poller.AshOban` | runtime, when a schedule is built |

A `poller:` that differs between compile time and runtime leaves the gauges
with no poller at all.

`prefix:` is never derived from `otp_app:`. Set it explicitly. A wrong metric
name is a permanent broken contract, and deriving one is unreliable at
compile time and in releases.

## The installer

```sh
mix igniter.install ash_metrics
```

That runs `Mix.Tasks.AshMetrics.Install`, which writes, never overwriting a
value already chosen:

- `prefix:` and `otp_app:` in `config/config.exs`, both set to the
  application being installed into;
- `poll: false` in `config/test.exs`;
- `:ash_metrics` in the formatter's `import_deps`;
- `++ AshMetrics.metrics()` onto the return value of `metrics/0` in the
  module that imports `Telemetry.Metrics`;
- `AshMetrics.Supervisor` into the application's children, after the
  repositories and Oban.

It only prints, and writes nothing, for: the optional keys with their
defaults; how to select `AshMetrics.Poller.AshOban` when the application
depends on `ash_oban`; how to select `AshMetrics.Backend.Otel` when it
depends on `otel_telemetry_metrics`; and a reporter snippet to add by hand
when no module imports `Telemetry.Metrics`.
