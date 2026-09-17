# AshMetrics

**Status:** pre-release, not on Hex. Counters, distributions, gauges with their
polling from either a timer or Oban, the emission API, the behaviours and the
test helpers work. The OpenTelemetry backend does not exist yet; with the
default `Backend.Noop` the host application's own reporter ships the metrics.

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
- **`distribution`** — "What's the spread?" Observed manually.

## Installation

Once the package is on Hex, one command does the whole installation:

```sh
mix igniter.install ash_metrics
```

It adds the dependency and then does the three things that are otherwise easy
to forget. It writes `prefix` and `otp_app` to `config/config.exs`, derived
from your application's name and never overwriting a value you have already
chosen. It appends `++ AshMetrics.metrics()` to the `metrics/0` of the module
that imports `Telemetry.Metrics` and defines it — `MyAppWeb.Telemetry` in a
generated Phoenix application — so the reporter you already start ships the
declared metrics too. And it adds `AshMetrics.Supervisor` to your
application's children, after the repositories, since a gauge is answered by a
query. When there is no such telemetry module it prints the reporter snippet
to add by hand rather than guessing which reporter you want, and it prints the
optional configuration keys with their defaults either way. Running it again
changes nothing.

The package is not on Hex yet, so that command does not work for anyone else
so far. Until it does, and for a project that would rather not run an
installer, the same installation by hand is three steps: add the dependency,
write the configuration block below, and wire the metrics into your reporter
and supervision tree as [Wiring into your
reporter](#wiring-into-your-reporter) describes.

Configuration:

```elixir
config :ash_metrics,
  prefix: "myapp",                                  # REQUIRED
  otp_app: :my_app,                                 # REQUIRED
  outcome_tag: :outcome,
  name_builder: AshMetrics.NameBuilder.Default,
  tag_extractor: AshMetrics.TagExtractor.Default,
  backend: AshMetrics.Backend.Noop,
  poller: AshMetrics.Poller.GenServer,
  tenant_source: MyApp.Tenants                      # :context multitenancy only

# Only when the Oban poller is chosen; see "Polling with Oban".
config :ash_metrics, AshMetrics.Poller.AshOban,
  queue: :default,
  max_attempts: 1
```

`prefix` must be set in compile-time configuration — `config/config.exs`, not
`config/runtime.exs` alone. A compile-time verifier rejects a resource that
declares metrics unless it is configured; the metric names themselves are
built when `AshMetrics.metrics/0` runs. It is required rather than derived from
`otp_app` because looking up the owning application at compile time is
unreliable, and a metric name is a permanent contract that cannot be quietly
wrong.

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
    #   tags: outcome, provider, template, tenant
    counter :delivery,
      outcomes: [:queued, :sent, :bounced, :delivered, :error],
      tags: [:provider, :template],
      description: "Templated deliveries by outcome"

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
      tags: [:provider]
  end
end
```

Emit them where the outcome becomes known — not from the action lifecycle,
because an action returning `{:ok, _}` means the function returned an ok tuple,
not that the email was delivered:

```elixir
AshMetrics.increment(MyApp.Mailings.TemplatedDelivery, :delivery,
  outcome: :sent,
  tags: %{provider: "ses", template: "welcome_v2"},
  metadata: changeset.context
)

AshMetrics.observe(MyApp.Mailings.TemplatedDelivery, :send_latency, 142,
  tags: %{provider: "ses"},
  metadata: changeset.context
)
```

`metadata:` is the bridge to the `AshMetrics.TagExtractor`. Pass anything shaped
like Ash event metadata — a changeset's context will do — and the extractor
pulls the tags that belong on every emission. The default pulls the tenant, and
refuses to stringify a struct into a tag value.

An outcome that was not declared, or a tag key that was not allowed, raises
rather than emitting.

The declarations themselves are checked while the resource compiles: metric
names must be unique, a counter needs at least one outcome and no duplicates,
tag keys must be unique and must not collide with the outcome tag or with the
keys the tag extractor adds, and buckets must be strictly ascending positive
numbers. Spark reports a failed check as a compiler warning that points at the
offending declaration, not as a hard error, so compile with
`mix compile --warnings-as-errors` in CI if a bad declaration should fail the
build.

See the [DSL reference](documentation/dsls/DSL-AshMetrics.md) for every option.

### Gauges

A gauge is the one primitive you never emit. AshMetrics polls it every `period`
and emits one value per group, so the declaration above publishes
`myapp.mailings.templated_delivery.backlog.gauge` with a `status` and a
`provider` tag and one timeseries per combination that exists.

What a poll costs is worth knowing before you shorten a period. Ash has no
`GROUP BY`, so the default `:count` strategy runs one read to learn which
groups exist and then one exact count per group: `1 + groups` queries per
period, and per tenant for a `:context` multitenant resource. Queries run with
`authorize?: false`, because a poll has no actor and a gauge that counted only
what someone may see would misreport the table. When that is too expensive,
declare `strategy: MyApp.Stats.Backlog` — any module implementing
`AshMetrics.Gauge.Strategy` — and compute the number however you like.

Sub-minute periods are usually wasted resolution: most collectors flush on a
ten second interval anyway, and every poll costs the queries above.

A group that disappears is emitted once as a zero. Without that, a
`last_value` metric would report the backlog's last non-zero value forever
after it drained, which is exactly when someone is looking at it.

### Polling with Oban

The default `AshMetrics.Poller.GenServer` runs a timer on every node, which
means every node polls, a failed poll is a log line, and how long polling
takes is nobody's business. An application that already runs Oban has better
answers to all three, and `AshMetrics.Poller.AshOban` uses them: Oban's cron
plugin inserts one job per period for the whole cluster, a failed poll is a
failed job with its error in Oban Web, and each gauge has its own worker and
queue entry, so its duration and failure rate are things Oban already
measures.

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

`max_attempts` defaults to one on purpose. A gauge answers a question about
the present, so retrying a poll that failed three minutes ago answers a
different question than the one that failed; the next scheduled poll is the
better retry.

One resource at a time works too, which is the usual shape: one expensive
backlog on the queue, the cheap gauges on the timer.

```elixir
metrics do
  poller AshMetrics.Poller.AshOban

  gauge :backlog, filter: expr(status == :pending), period: :timer.minutes(5)
end
```

Three things have to be true for such a resource.

- **It uses the `AshOban` extension**, which owns the `oban` section the
  schedules are added to: `extensions: [AshOban, AshMetrics]`.
- **Every gauge's `period` is a whole number of minutes from 1 to 59, of
  hours from 1 to 23, or exactly one day.** Cron cannot express anything
  else, and rounding silently would make the declaration disagree with the
  schedule.
- **The queue exists in your Oban configuration, and the crontab is the one
  `AshOban.config/2` built**, or the schedules are never registered:

  ```elixir
  config :my_app, Oban,
    AshOban.config(
      Application.fetch_env!(:my_app, :ash_domains),
      repo: MyApp.Repo,
      queues: [default: 10],
      plugins: [Oban.Plugins.Cron]
    )
  ```

The first two are compile errors naming the gauge, rather than warnings: a
transformer that cannot build the schedule has no valid resource to hand on.

What it generates is invisible but not secret. Each gauge gets a private
generic action `__ash_metrics_emit_<gauge>__` and a matching entry in the
resource's `oban.scheduled_actions`. The actions are not public, so
`ash_json_api` and `ash_graphql` do not expose them, and the underscores say
that nothing should call them by hand — `AshMetrics.Gauge.Runner.emit/3` is
how you poll a gauge from code.

One thing is weaker than with the timer. Zeroing a group that has drained
means remembering the groups the previous poll found, and an Oban job has no
state between runs, so `AshMetrics.Poller.AshOban.Memory` keeps that in
`:persistent_term` — per node, not persisted, best effort. Since the cron is a
cluster-wide singleton, a vanished group is zeroed by each node that had seen
it the next time that node runs the job, and a freshly started node zeroes
nothing at all. A gauge whose groups come and go constantly is better served
by the timer, where every node polls and every node remembers.

### Multitenancy

Multitenant resources are polled differently depending on what Ash will let a
query do, but a gauge is tagged with `tenant` either way:

- `:attribute` with `global? true` — one query covers every tenant, grouped by
  the tenant attribute. Nothing needs configuring.
- `:attribute` without `global? true` — Ash refuses a read that names no
  tenant, so the gauge is polled once per tenant of the configured
  `tenant_source`, a module implementing `AshMetrics.TenantSource`. AshMetrics
  will not ask you to turn `global?` on to save the queries: that widens
  tenantless reads for your whole application, which is not a trade to make
  for a metric.
- `:context` — each tenant's rows live in their own schema, so the gauge is
  polled once per tenant of the same `tenant_source`.

A compile-time verifier rejects a resource that has to be polled per tenant
and declares a gauge while `tenant_source` is unset, because such a gauge
would otherwise be polled for nobody and emit nothing.

Note the multiplier: a gauge polled per tenant costs its queries once per
tenant per period.

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
by every poller in use — the gauges are grouped by the poller that polls them,
and each is asked once for its own. Put it after your repository, since a
gauge is answered by a query. `AshMetrics.child_specs/1` returns the same
children as a list, for a tree that would rather splice them in than add a
supervisor. With the default `AshMetrics.Backend.Noop` the backend adds
nothing, which is the right answer when you already run a reporter of your
own. Pass an explicit resource list to `AshMetrics.metrics_for/1` if domain
discovery is not what you want.

With the default poller every node polls, so in a cluster each gauge is
computed and emitted once per node per period. A `last_value` of the same
number reported by five nodes is still that number, but the queries behind it
are not free. That is what
[polling with Oban](#polling-with-oban) is for, and
`AshMetrics.Poller` is the behaviour to implement for anything else.

## Testing

```elixir
defmodule MyApp.MailingsTest do
  use ExUnit.Case, async: false
  use AshMetrics.Test

  test "a delivery emits a sent counter" do
    MyApp.Mailings.deliver!(...)

    assert_metric_emitted "myapp.mailings.templated_delivery.delivery",
      outcome: :sent,
      tags: %{provider: "ses"}

    refute_metric_emitted "myapp.mailings.templated_delivery.delivery",
      outcome: :bounced
  end
end
```

`use AshMetrics.Test` attaches a handler for the duration of each test and
imports the assertions. Name the metric as the declaration produces it, without
the `.count`, `.gauge` or `.duration` suffix a reporter adds. `:telemetry` handlers are
global, so keep such modules `async: false` — see `AshMetrics.Test` for the
details.

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
publishes Postgres on `${ASH_METRICS_PG_PORT:-54329}`, well away from the
default so it cannot collide with another instance on the same machine; set
that variable if 54329 is taken. Only ever drive it through `docker compose`
from the repository root, so that no container outside this project is
touched.

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
