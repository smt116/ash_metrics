<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Gauges

Never emit a gauge. It has no call site: AshMetrics polls it every `period:`
and emits one value per group. `AshMetrics.increment/3` and
`AshMetrics.observe/4` raise when pointed at one.

```elixir
gauge :backlog,
  filter: expr(status == :pending and inserted_at > ago(1, :hour)),
  group_by: [:status, :provider],
  period: :timer.minutes(5),
  description: "Deliveries waiting to be sent"
```

## Filtering and grouping

`filter:` is an Ash expression, written with `expr/1` exactly as anywhere else
in the resource; `Ash.Expr` is imported into the `metrics` section. Use
`ago/2` for a time window: a timestamp computed in the declaration itself is
evaluated once, while the resource compiles.

`group_by:` names attributes of the resource, and each combination of their
values is one timeseries. Group only by attributes with a small, bounded set
of values — a status, a provider, a type. Grouping by an identifier, an email
address or a free-text column publishes one timeseries per row.

## Cost

The default `:count` strategy has no `GROUP BY` to work with: it reads the
distinct values of `group_by:` to learn which groups exist, then runs one
count per group. That is `1 + groups` queries per period, multiplied by the
number of tenants for a resource polled per tenant. A gauge with no
`group_by:` is a single count. Every query runs with `authorize?: false`.

`AshMetrics.Gauge.Strategy.OldestAge` reports the age in whole seconds of the
oldest matching row per group instead of a count, at the cost of `:count`.
It measures from `inserted_at` unless `attribute:` names another timestamp
attribute; a naive timestamp is read as UTC. An empty set reads 0, exactly as
a row written within the last second does, so alert on the age together with
a count of the same rows rather than on the age alone. It needs a data layer
supporting an Ash `:min` aggregate; a compile-time verifier rejects it on one
that does not, such as `Ash.DataLayer.Simple`.

```elixir
gauge :backlog_age,
  filter: expr(status == :pending),
  group_by: [:provider],
  strategy: {AshMetrics.Gauge.Strategy.OldestAge, attribute: :queued_at}
```

Keep `period:` at a minute or more. Most collectors flush on a ten second
interval, so a shorter period buys resolution nothing reads and pays for it
in queries every time.

On a resource whose data layer is `AshPostgres.DataLayer`, declare
`strategy: AshMetrics.Gauge.Strategy.Postgres.Count` to get the same counts
from one `GROUP BY` query per period, per tenant where the resource is polled
per tenant. It honours the base filter, the primary read action's
preparations and both multitenancy strategies exactly as `:count` does. A
compile-time verifier rejects it on any other data layer, and selecting it
without `ash_postgres` in the dependencies is a hard compile error. Do not
rely on either strategy for a resource whose primary read action's
preparations set a limit or an offset: both read a truncated set of rows,
and their results differ.

When the count is too expensive, or the number is cheaper to obtain some
other way — a database statistics estimate, a cached value — point
`strategy:` at a module implementing the `AshMetrics.Gauge.Strategy`
behaviour:

```elixir
gauge :backlog,
  filter: expr(status == :pending),
  group_by: [:status],
  strategy: MyApp.Stats.Backlog
```

A strategy that takes options is declared as `{module, options}`, with
`options` a keyword list; the strategy reads them from the gauge's
`strategy_opts`:

```elixir
gauge :backlog,
  group_by: [:status],
  strategy: {MyApp.Stats.Backlog, sample: 0.1}
```

A strategy returns `{tags, value}` per group and returns `{:error, reason}`
rather than raising. It returns no entry at all for a group with no rows.

A strategy that takes options, or needs something of the resource, implements
the optional `c:AshMetrics.Gauge.Strategy.verify/2` to check the gauge while
the resource compiles. Its `{:error, message}` is reported at the gauge as a
compiler warning, not an error. In that callback, reject every key of the
gauge's `strategy_opts` the strategy does not take, and check that every
attribute an option names exists with `Ash.Resource.Info.attribute/2` on the
DSL state; never ignore an unknown option.

## Groups that vanish

A gauge compiles to a last-value metric, which keeps reporting the last thing
it was told. A group that drains away is therefore zeroed: the runner emits
one zero for every group the previous poll found and this one did not, once.
A backend implementing `c:AshMetrics.Backend.report_gauge/3` takes the poll's
groups instead and zeroes vanished ones itself.

## Multitenancy

Every gauge on a multitenant resource carries a `tenant` tag, under either of
Ash's strategies. What you have to configure differs:

- `:context`, or `:attribute` without `global? true` — Ash refuses to read
  without a tenant, so the gauge is polled once per tenant of the configured
  `tenant_source:`, a module implementing `AshMetrics.TenantSource`. A
  compile-time verifier rejects such a resource that declares a gauge while
  no source is configured.
- `:attribute` with `global? true` — nothing to configure. One query grouped
  by the tenant attribute covers every tenant at once.

Mind the multiplier in the first case: the cost above is paid once per tenant
per period.
