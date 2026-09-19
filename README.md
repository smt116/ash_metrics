# AshMetrics

[![Hex.pm](https://img.shields.io/hexpm/v/ash_metrics.svg)](https://hex.pm/packages/ash_metrics) [![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/ash_metrics)

**Experimental.** The DSL, the configuration keys and the public API may
change between minor releases until 1.0. Every such change is listed in the
[changelog](CHANGELOG.md).

## What it is

AshMetrics is an Ash resource extension that adds a `metrics do` block for
declarative *business* metrics: counts and rates of business events (emails
sent, invoices captured, syncs completed), the current depth of state-machine
backlogs (how many records are `pending` right now), and latency
distributions. Declarations sit next to the action they describe, are validated
at compile time, carry a uniform set of tags without every call site repeating
them, and enforce a tag allowlist that keeps high-cardinality values out.

Those declarations compile into a list of `Telemetry.Metrics` structs, which the
host application's existing reporter ships to whatever backend it already uses —
OTLP, StatsD, Prometheus, AppSignal. Counter emission is a synchronous
`:telemetry.execute/3`; periodic polling is only needed for gauges.

## Primitives

- **`counter`** — "How many events? How fast?" Emitted where the fact is
  written: by hand with `increment/3`, or by an action change.
- **`gauge`** — "How many right now?" Filled by a package-managed periodic poll
  over the resource.
- **`distribution`** — "What's the spread?" Observed by hand with `observe/4`,
  or by `observe_elapsed/2` on an action.

## Installation

One command does the whole installation:

```sh
mix igniter.install ash_metrics
```

It adds the dependency, writes `prefix` and `otp_app` to `config/config.exs`
and `poll: false` to `config/test.exs`, imports the package's formatter
configuration, appends `++ AshMetrics.metrics()` to the `metrics/0` of the
module that imports `Telemetry.Metrics` — `MyAppWeb.Telemetry` in a generated
Phoenix application — and adds `AshMetrics.Supervisor` to your application's
children after the repositories and Oban. It never overwrites a value you have
already chosen, prints the optional configuration keys with their defaults,
prints how to select the Oban poller or the OpenTelemetry backend when
`ash_oban` or `otel_telemetry_metrics` is among your dependencies, and prints a
reporter snippet to add by hand when it finds no telemetry module. See
`mix ash_metrics.install`.

To install by hand, add the dependency:

```elixir
{:ash_metrics, "~> 0.3"}
```

Then write the configuration block below and wire the metrics into your
reporter and supervision tree as
[Wiring into your reporter](#wiring-into-your-reporter) describes.

Configuration:

```elixir
config :ash_metrics,
  prefix: "myapp",                                  # REQUIRED
  otp_app: :my_app,                                 # REQUIRED
  name_builder: AshMetrics.NameBuilder.Default,
  tag_extractor: AshMetrics.TagExtractor.Default,
  backend: AshMetrics.Backend.Noop,                 # Backend.Otel for OpenTelemetry
  poller: AshMetrics.Poller.GenServer,
  poll: true,                                       # false starts no poller
  tenant_source: MyApp.Tenants                      # per-tenant gauges only

# Only when the Oban poller is chosen; see "Polling with Oban".
config :ash_metrics, AshMetrics.Poller.AshOban,
  queue: :default,
  max_attempts: 1
```

`prefix` must be set in compile-time configuration — `config/config.exs`, not
`config/runtime.exs` alone — and is never derived from `otp_app`. A
compile-time verifier rejects a resource that declares metrics unless it is
configured; the metric names themselves are built when `AshMetrics.metrics/0`
runs.

`otp_app` is the application whose Ash domains `AshMetrics.metrics/0` searches
to find the resources that declare metrics.

## Usage

Declare metrics on the resource:

```elixir
defmodule MyApp.Mailings.TemplatedDelivery do
  use Ash.Resource,
    domain: MyApp.Mailings,
    extensions: [AshMetrics]

  metrics do
    # Optional; defaults to the resource short name.
    name :templated_delivery

    # → myapp.mailings.templated_delivery.delivery.count
    #   tags: provider, template, status, tenant
    counter :delivery,
      tags: [:provider, :template, status: [:queued, :sent, :bounced, :delivered, :error]],
      description: "Templated deliveries by status"

    # → myapp.mailings.templated_delivery.backlog.gauge
    #   tags: status, provider
    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status, :provider],
      period: :timer.minutes(1),
      description: "Deliveries waiting to be sent"

    # → myapp.mailings.templated_delivery.send_latency.duration
    #   tags: provider, tenant
    distribution :send_latency,
      unit: {:native, :millisecond},
      buckets: [10, 50, 100, 250, 500, 1_000, 5_000],
      tags: [provider: [:ses, :smtp]]
  end
end
```

A tag entry written `key: [value, ...]` is a closed tag: every emission must
carry it, with one of the listed values, and the whole enumeration lives in one
metric name rather than one name per value. An entry written `key` is open, and
a call site may pass any value or none at all. A distribution's value is
measured by the call site, not by the package.

The declarations themselves are checked while the resource compiles: metric
names must be unique, tag keys must be unique and must not collide with the
keys the tag extractor adds, a closed tag needs at least one value and no
duplicates, and buckets must be strictly ascending positive numbers. Spark
reports a failed check as a compiler warning pointing at the offending
declaration, so compile with `mix compile --warnings-as-errors` in CI if a bad
declaration should fail the build.

See the [DSL reference](documentation/dsls/DSL-AshMetrics.md) for every option.

Emit them where the outcome becomes known: an action returning `{:ok, _}` does
not mean the email was delivered, so nothing is emitted from the action
lifecycle unless the action says so.

```elixir
AshMetrics.increment(MyApp.Mailings.TemplatedDelivery, :delivery,
  tags: %{status: :sent, provider: "ses", template: "welcome_v2"},
  metadata: changeset.context
)

AshMetrics.observe(MyApp.Mailings.TemplatedDelivery, :send_latency, 142,
  tags: %{provider: :ses},
  metadata: changeset.context
)
```

`metadata:` is the bridge to the `AshMetrics.TagExtractor`. Pass anything shaped
like Ash event metadata — a changeset's context will do — and the extractor
pulls the tags that belong on every emission. The default pulls the tenant, and
refuses to stringify a struct into a tag value.

A missing closed tag, a value that tag does not declare, or a tag key that was
not declared at all raises rather than emitting.

### Emitting from actions

When the fact is written by an Ash action, that action can emit it:

```elixir
update :update_status do
  accept [:status, :delivered_at]
  require_atomic? false

  change AshMetrics.increment_on_change(:delivery, :status)

  change AshMetrics.observe_elapsed(:delivery_time,
           from: :inserted_at,
           to: :delivered_at
         ),
         where: [attribute_equals(:status, :delivered)]
end
```

`increment_on_change/2` counts one `delivery` after the transaction whenever
the action leaves `status` holding a value the record did not have before,
tagged with that value and with every other declared tag of the counter that
names an attribute of the record. `observe_elapsed/2` records the time
between two timestamps of the written record into `delivery_time`, in that
distribution's unit; `where:` narrows it to the one transition that means
delivered. Both take their extractor metadata from the changeset, emit
nothing when the action fails, and never alter its result. See
`AshMetrics.Changes.IncrementOnChange` and `AshMetrics.Changes.ObserveElapsed`.

`increment_on_write/2` counts every write of the attribute instead of every
change of it, so a create counts and an update writing the same value again
counts again:

```elixir
update :record_attempt do
  accept [:status]

  change AshMetrics.increment_on_write(:delivery, :status)
end
```

Two caveats. A value outside a closed tag's declared set is skipped, so a
status the counter does not enumerate is not counted and nothing is raised.
And `increment_on_change/2` refuses to run atomically: the action needs
`require_atomic? false`, and `Ash.bulk_update/4` needs `:stream` among its
strategies, or it emits nothing and returns
`Ash.Error.Invalid.NoMatchingBulkStrategy`. `increment_on_write/2` and
`observe_elapsed/2` run atomically unless the `change` carries a `where:`
whose condition reads an attribute, as the one above does.
`Ash.bulk_create/4` needs nothing extra.

### Gauges

A gauge is the one primitive you never emit. AshMetrics polls it every `period`
and emits one value per group, so the declaration above publishes
`myapp.mailings.templated_delivery.backlog.gauge` with a `status` and a
`provider` tag and one timeseries per combination that exists.

A poll costs queries: the default `:count` strategy runs `1 + groups` of them
per period, again per tenant for a resource that is polled per tenant, and runs
them with `authorize?: false`. See `AshMetrics.Gauge.Strategy.Count`. When that
is too expensive, declare `strategy: MyApp.Stats.Backlog` — any module
implementing `AshMetrics.Gauge.Strategy` — and compute the number however you
like.

Sub-minute periods are usually wasted resolution: most collectors flush on a
ten second interval anyway, and every poll costs the queries above.

A group that disappears is emitted once as a zero, so a drained backlog does
not keep reporting its last value; see `AshMetrics.Gauge.Runner`. A backend
that takes the poll's result, such as `AshMetrics.Backend.Otel`, zeroes it
itself.

### Polling with Oban

The default `AshMetrics.Poller.GenServer` runs a timer on every node.
`AshMetrics.Poller.AshOban` polls from Oban's cron instead: one job per period
for the whole cluster, a failed poll as a failed job with its error in Oban
Web, and one worker and queue entry per gauge.

```elixir
# In config/config.exs: the choice is read while resources compile.
config :ash_metrics, poller: AshMetrics.Poller.AshOban

config :ash_metrics, AshMetrics.Poller.AshOban,
  queue: :default,
  max_attempts: 1
```

Like `prefix`, the poller has to be compile-time configuration: the schedules
are generated while the resource compiles, and a poller that differs between
compile time and runtime leaves the gauges with no poller at all.

The poller can also be chosen per resource, for example one expensive backlog
on the queue and the remaining gauges on the timer:

```elixir
metrics do
  poller AshMetrics.Poller.AshOban

  gauge :backlog, filter: expr(status == :pending), period: :timer.minutes(5)
end
```

Such a resource must use the `AshOban` extension, must declare gauge periods
cron can express exactly, and needs its queue and its `AshOban.config/2`
crontab in the host application's Oban configuration; the first two are compile
errors naming the gauge. Zeroing a drained group is weaker than with the timer,
since an Oban job has no state between runs. See `AshMetrics.Poller.AshOban`
for all of it, and for the private action and schedule it generates per gauge.

With `AshMetrics.Backend.Otel`, the poll's result is exported from the node
that ran the job, one series per gauge for the cluster, and drained groups are
zeroed by the backend, not by that memory; see
[OpenTelemetry](#opentelemetry).

### Multitenancy

A gauge is tagged with `tenant` under either of Ash's multitenancy strategies.
A resource Ash will not read without a tenant — `:context`, or `:attribute`
without `global? true` — is polled once per tenant of the configured
`tenant_source`, a module implementing `AshMetrics.TenantSource`, and a
compile-time verifier rejects such a resource that declares a gauge while
`tenant_source` is unset. `:attribute` with `global? true` needs no
configuration.

Note the multiplier: a gauge polled per tenant costs its queries once per
tenant per period. See `AshMetrics.Gauge.Runner` for how each strategy is
polled.

## Wiring into your reporter

`AshMetrics.metrics/0` returns the `Telemetry.Metrics` definitions of every
resource that declares metrics. Splice it into whatever reporter you already
run:

```elixir
defmodule MyApp.Telemetry do
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {Telemetry.Metrics.ConsoleReporter, metrics: my_own_metrics() ++ AshMetrics.metrics()},
      AshMetrics.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

The same list works for a Prometheus reporter:

```elixir
{TelemetryMetricsPrometheus, metrics: AshMetrics.metrics()}
```

`AshMetrics.Supervisor` starts whatever the configured backend needs, followed
by every poller in use. Put it after your repository, since a gauge is answered
by a query. `AshMetrics.child_specs/1` returns the same children as a list, for
a tree that would rather splice them in than add a supervisor. With the default
`AshMetrics.Backend.Noop` the backend adds nothing. Pass an explicit resource
list to `AshMetrics.metrics_for/1` if domain discovery is not what you want.

With the default poller every node polls, so in a cluster each gauge is
computed and emitted once per node per period; see
`AshMetrics.Poller.GenServer`, [polling with Oban](#polling-with-oban), and
`AshMetrics.Poller` for implementing anything else.

### OpenTelemetry

An application exporting through OpenTelemetry with the
`otel_telemetry_metrics` bridge selects the backend that adapts the definitions
for it:

```elixir
config :ash_metrics, backend: AshMetrics.Backend.Otel
```

The application keeps its own `OtelTelemetryMetrics` instance and splices
`AshMetrics.metrics()` into the list it hands it:

```elixir
{OtelTelemetryMetrics, metrics: my_own_metrics() ++ AshMetrics.metrics()}
```

Counters and distributions go through the bridge; a declared `buckets` list is
carried on as the histogram's bucket boundaries. Gauges do not: the backend
exports each one as an OpenTelemetry observable gauge serving the values the
configured poller reports to it, so the pollers must run — with `poll: false`
no gauge is exported. With `AshMetrics.Poller.AshOban` that is one
query and one series per gauge for the whole cluster; with the default timer
poller, one of each per node. A series carries the exporting node's resource
attributes, so aggregate over `host` when querying, and when the poll moves to
another node both export it for up to one period. See
`AshMetrics.Backend.Otel`.

## Testing

```elixir
defmodule MyApp.MailingsTest do
  use ExUnit.Case, async: false
  use AshMetrics.Test

  test "a delivery emits a sent counter" do
    MyApp.Mailings.deliver!(...)

    assert_metric_emitted "myapp.mailings.templated_delivery.delivery",
      tags: %{status: :sent, provider: "ses"}

    refute_metric_emitted "myapp.mailings.templated_delivery.delivery",
      tags: %{status: :bounced}
  end
end
```

`use AshMetrics.Test` attaches a handler for the duration of each test and
imports the assertions. Name the metric as the declaration produces it, without
the aggregation suffix a reporter adds. `:telemetry` handlers are global, so
keep such modules `async: false` — see `AshMetrics.Test` for the details.

The installer writes `config :ash_metrics, poll: false` to `config/test.exs`,
which keeps gauges from being polled while tests run. To poll them in a test,
set it to `true` there or pass `poll: true` to `AshMetrics.Supervisor`.

## Development

`mix test` runs the whole suite except the Postgres integration tests, and
needs no database and no container. The tests that do need one are tagged
`:postgres`, excluded by default, and run against the container this
repository's `docker-compose.yml` defines:

```sh
docker compose up -d
mix test.integration
docker compose stop
```

`mix test.integration` creates the database, migrates it and runs everything
with `--include postgres`. The container is named `ash_metrics-postgres-1` and
publishes Postgres on `${ASH_METRICS_PG_PORT:-54329}`; set that variable if
54329 is taken. Only ever drive it through `docker compose` from the repository
root, so that no container outside this project is touched.

The rest of the checks:

```sh
mix format --check-formatted
mix credo --strict
mix dialyzer
mix docs
```

`mix docs` regenerates the DSL cheat sheet in `documentation/dsls`, which is
checked in; commit it with whatever DSL change produced it.

## Non-goals

- Not a new emit/aggregate/export pipeline. AshMetrics produces
  `Telemetry.Metrics` structs and lets the existing reporter ecosystem ship them.
- Not an APM or tracing tool. `ash_appsignal` and `opentelemetry_ash` cover that.
- Not a replacement for `Oban.Telemetry`, which already emits job `queue_time`
  and `duration`.

## License

MIT. See the `LICENSE` file in the repository root.
