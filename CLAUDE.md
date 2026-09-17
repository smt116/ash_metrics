# AshMetrics

`ash_metrics` is a generic, publishable Ash extension that adds a `metrics do`
block to an Ash resource. Declarations in that block compile into a list of
`Telemetry.Metrics` structs that the host application's existing reporter ships
to whatever backend it already uses; the package is not an emit/aggregate/export
pipeline of its own. When `tmp/ash_metrics_design.md` is present locally it is
the authoritative design document — read it before changing behaviour. It is
gitignored, so it may be absent; do not recreate it.

## Commands

All of these must pass before any piece of work is considered done:

- `mix test`
- `mix test.integration`
- `mix format` (or `mix format --check-formatted`)
- `mix credo --strict`
- `mix dialyzer`
- `mix docs`

`mix test` alone must never require Docker: the tests that need a database are
tagged `:postgres` and excluded by default. `mix test.integration` includes
them and needs the container from this repository's `docker-compose.yml`
(`docker compose up -d`, `docker compose stop`). Drive only that compose file,
only from the repository root; never touch another container on the machine.

## Design principles

These are decisions already made. Do not relitigate them in code.

- **Generic, never consumer-specific.** Nothing about any particular
  application is hardcoded. Anything an adopter needs must be reachable through
  configuration.
- **The design test.** Before adding anything, ask: would this work,
  unmodified, for a single-tenant Phoenix app exporting to Prometheus, with no
  Oban and no OpenTelemetry? If the answer is no, something app-specific has
  leaked in.
- **Optional dependencies stay optional.** Guard any module backed by an
  optional dep with `Code.ensure_loaded?/1`, and raise a clear compile error if
  a selected backend or poller's dependency is missing.
- **Counters are manual by design.** Never auto-emit counters from the Ash
  action lifecycle. An action returning `{:ok, _}` means the function returned
  an ok tuple, not that the business outcome happened; outcomes often land in a
  notifier or webhook long afterwards.
- **Outcome is a tag, not a name segment.** A counter with five outcomes is one
  metric name carrying an `outcome` tag with five values, not five metric names.
  `outcomes:` in the DSL compiles to a compile-time-validated tag-value set.
- **`prefix` is required configuration, never derived.** Deriving it from
  `otp_app` is unreliable at compile time and in releases, and a wrong metric
  name is a permanent broken contract. A verifier rejects the resource when it
  is absent.
- **Verifier failures are compiler warnings, not errors.** Spark catches a
  verifier's `DslError` and reports it through `IO.warn` with the declaration's
  location; `mix compile` still succeeds unless `--warnings-as-errors` is on.
  Do not document them as hard compile errors. Tests for verifiers therefore go
  through `Spark.Test.dsl_errors/1` (see `test/support/compiler.ex`), not
  `assert_raise`.
- **`before_action`/`after_action` telemetry is never a metrics source.** Ash's
  own docs warn against it: the cardinality is extremely high and there is no
  name to distinguish instances.
