# AshMetrics

**Status:** pre-release, not on Hex. Counters, distributions, the emission API,
the behaviours and the test helpers work; gauges and their pollers do not exist
yet.

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
  over the resource. Not implemented yet.
- **`distribution`** — "What's the spread?" Observed manually.

## Installation

The package is not published yet, so there is no dependency to add. Hex
publication is pending.

Configuration, once it is:

```elixir
config :ash_metrics,
  prefix: "myapp",                                  # REQUIRED
  otp_app: :my_app,                                 # REQUIRED
  outcome_tag: :outcome,
  name_builder: AshMetrics.NameBuilder.Default,
  tag_extractor: AshMetrics.TagExtractor.Default,
  backend: AshMetrics.Backend.Noop
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
    children =
      [
        {Telemetry.Metrics.ConsoleReporter, metrics: my_own_metrics() ++ AshMetrics.metrics()}
      ] ++ AshMetrics.Backend.child_specs()

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

The same list works for a Prometheus reporter:

```elixir
{TelemetryMetricsPrometheus, metrics: AshMetrics.metrics()}
```

`AshMetrics.Backend.child_specs/0` starts whatever the configured backend needs.
With the default `AshMetrics.Backend.Noop` it returns `[]`, which is the right
answer when you already run a reporter of your own. Pass an explicit resource
list to `AshMetrics.metrics_for/1` if domain discovery is not what you want.

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
the `.count` or `.duration` suffix a reporter adds. `:telemetry` handlers are
global, so keep such modules `async: false` — see `AshMetrics.Test` for the
details.

## Non-goals

- Not a new emit/aggregate/export pipeline. AshMetrics produces
  `Telemetry.Metrics` structs and lets the existing reporter ecosystem ship them.
- Not an APM or tracing tool. `ash_appsignal` and `opentelemetry_ash` cover that.
- Not a replacement for `Oban.Telemetry`, which already emits job `queue_time`
  and `duration`.

## License

MIT. See the `LICENSE` file in the repository root.
