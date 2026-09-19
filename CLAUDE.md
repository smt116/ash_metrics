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

## Documentation

Applies to every `@moduledoc`, `@doc`, `@typedoc`, `describe:` text and `#`
comment, in `lib/` and `test/` alike.

- **State the contract, not the reasoning.** What a thing is for, its inputs,
  outputs, options, errors and guarantees, and the constraints or caveats a
  caller must know. Nothing else.
- **Never defend a decision.** No paragraph explaining why this name, why a
  module rather than a capture, why compile time, why an earlier approach was
  rejected. No "deliberately", "on purpose", "rather than X, which would...".
  Where a choice has a consequence the reader must act on, state the
  consequence in one sentence and stop.
- **One fact, one home.** Document each fact in the module whose code enforces
  it; everywhere else says nothing or cross-references it in a single
  sentence. The same explanation in a moduledoc, a function doc, the README and
  the CHANGELOG is three copies too many.
- **Reference register, not blog.** No rhetorical openers or closers, no
  self-referential asides. A comment earns its place when deleting it would let
  a maintainer make a wrong change; otherwise delete it.
- **The usage rules are exempt from one home.** `usage-rules.md` and
  `usage-rules/` are consumer-facing and imperative, addressed to an agent
  writing code with the package, and may restate facts documented elsewhere.
  Every sentence in them must be true of the code at every commit;
  `test/usage_rules_test.exs` checks the references they name, nothing more.

Re-read `usage-rules.md` and `usage-rules/` with every behaviour change, and
update what the change made wrong.

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
- **Counters are emitted where the fact is written.** By hand, or by
  `increment_on_change` on the action that writes it; never inferred from an
  action succeeding. An action returning `{:ok, _}` means the function returned
  an ok tuple, not that the business outcome happened; outcomes often land in a
  notifier or webhook long afterwards.
- **An enumerated dimension is a tag, not a name segment.** A counter broken
  down five ways is one metric name carrying a tag with five values, never five
  metric names. A `tags` entry written `key: [value, ...]` declares that closed
  set; it is validated when the resource compiles and on every emission.
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
