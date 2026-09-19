<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Declaring metrics

## Pick the primitive by the question it answers

- `counter` — "How many events, and how fast?"
- `gauge` — "How many are there right now?"
- `distribution` — "What is the spread of this observed number?"

Declare them in a `metrics do` block on the resource the fact belongs to:

```elixir
defmodule MyApp.Mailings.TemplatedDelivery do
  use Ash.Resource,
    domain: MyApp.Mailings,
    extensions: [AshMetrics]

  metrics do
    # Optional; defaults to the resource short name.
    name :templated_delivery

    counter :delivery,
      tags: [:provider, :template, status: [:queued, :sent, :bounced, :delivered, :error]],
      description: "Templated deliveries by status"

    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status, :provider],
      period: :timer.minutes(1),
      description: "Deliveries waiting to be sent"

    distribution :send_latency,
      unit: {:native, :millisecond},
      buckets: [10, 50, 100, 250, 500, 1_000, 5_000],
      tags: [provider: [:ses, :smtp]]
  end
end
```

## Tags

`tags:` is an allowlist of the keys a call site may pass. An entry written
`key` is open: a call site may pass any value, or none. An entry written
`key: [value, ...]` is closed: every emission must carry that key with one of
the listed values.

Close a tag whenever the set of values is enumerable. An enumerated dimension
is a tag, not a name segment: one counter named `delivery` carrying
`status: [:sent, :bounced]` beats two counters named `delivery_sent` and
`delivery_bounced`.

Keyword syntax puts every closed entry at the end of the list. Write closed
entries as explicit tuples when they have to come earlier:

```elixir
tags: [:provider, :template, status: [:queued, :sent, :error]]
tags: [{:status, [:queued, :sent, :error]}, :provider, :template]
```

An entry written `key: [path: [...]]` says where in the written record the
action changes read the tag's value, descending through embedded attributes.
Add `values:` to close it as well:

```elixir
tags: [
  state: [path: [:location, :state]],
  shipping_state: [path: [:location, :shipping_address, :state], values: [:tx, :ca]]
]
```

The key is the tag's name, not an attribute name: name it for the dimension
it reports. `nil` at any segment of the path leaves the tag off the emission.
A call site passing that key to `AshMetrics.increment/3` or
`AshMetrics.observe/4` by hand passes the value itself; the path is read only
by the action changes.

A gauge has no `tags:`. Its tags are its `group_by:` attributes; see
`usage-rules/gauges.md`.

## Metric names are a permanent contract

A declaration compiles to
`<prefix>.<domain>.<resource>.<metric>` plus the suffix of its aggregation:
`.count` for a counter, `.gauge` for a gauge, and for a distribution the
suffix derived from its `unit` — `.duration` for a time unit or a conversion
tuple, `.bytes` for `:byte`, `:kilobyte` or `:megabyte`, `.value` for anything
else — unless it declares `suffix:` itself. The `delivery` counter above
becomes `myapp.mailings.templated_delivery.delivery.count`, and the
`send_latency` distribution
`myapp.mailings.templated_delivery.send_latency.duration`.

Renaming a shipped metric breaks every dashboard, alert and recording rule
built on it, and the old series does not migrate. Never rename one casually.

`name` in the `metrics` block overrides the resource segment only; the prefix
and the domain segment come from configuration and from Ash.

## Compile-time checks

The verifiers check that metric names are unique across all three primitives,
that tag keys are unique and do not collide with the tag extractor's keys,
that a closed tag lists at least one value and no duplicates, that buckets
are strictly ascending positive numbers, and that a gauge groups by
attributes of the resource.

They check a `path:` too: it must start at an attribute of the resource,
descend through embedded resources only, never through a list, and end at an
attribute that holds a single value. A tag with no path may not name an
attribute holding a map, a struct or an embedded resource either — give it a
path into that attribute, or name the value the call site passes.

A verifier failure is reported through `IO.warn` as a compiler warning
pointing at the declaration, not as a hard error. Compile with
`mix compile --warnings-as-errors` in CI, or a bad declaration ships.

The transformer behind the Oban poller is the exception: a resource that
selects `AshMetrics.Poller.AshOban` without the `AshOban` extension, or with
a gauge `period:` cron cannot express exactly, is a hard compile error naming
the gauge.
