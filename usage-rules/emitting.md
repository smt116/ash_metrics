<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Emitting counters and distributions

A gauge is never emitted; see `usage-rules/gauges.md`. For the other two, work
down this list and stop at the first case that fits.

1. **Every write of the attribute counts.** Use
   `AshMetrics.increment_on_write/2` on the action that writes it. It counts
   every `{:ok, record}`, so a create counts and an update writing the same
   value again counts again. It runs atomically: keep `require_atomic? true`,
   and `Ash.bulk_update/4` may use its `:atomic` strategy.

   ```elixir
   update :record_attempt do
     accept [:status]

     change AshMetrics.increment_on_write(:delivery, :status)
   end
   ```

2. **Only transitions count.** Use `AshMetrics.increment_on_change/2`, which
   compares the attribute with its original value and counts only when they
   differ; a create always counts. It reads the original value, so it is not
   atomic: put `require_atomic? false` on the action, and give
   `Ash.bulk_update/4` `strategy: :stream`. Without the stream strategy the
   update fails with `Ash.Error.Invalid.NoMatchingBulkStrategy` and emits
   nothing.

3. **The fact is an elapsed time between two timestamps of the record.** Use
   `AshMetrics.observe_elapsed/2` with `from:` and `to:`; `to:` defaults to
   `:now`, the moment the hook runs. Both attributes must be datetime
   attributes, and the distribution's `unit:` must be a plain time unit —
   `:second`, `:millisecond`, `:microsecond` or `:nanosecond`, never a
   conversion tuple such as `{:native, :millisecond}`. It runs atomically.

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

4. **The fact is known outside any action** — in a notifier, a webhook
   handler, a provider callback. Call `AshMetrics.increment/3` or
   `AshMetrics.observe/4` by hand, and pass `metadata:` so the configured tag
   extractor can add the tenant:

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

   `metadata:` takes anything shaped like Ash event metadata; a changeset's
   context is the usual thing to pass. Any map with a `tenant` key works.

## Traps

A `where:` on any of these changes whose condition reads an attribute —
`attribute_equals/2`, `data_one_of/2`, `changing/1` — cannot be decided
before the action runs and takes the action off the atomic path. That action
needs `require_atomic? false` and `strategy: :stream`, even with
`AshMetrics.increment_on_write/2` or `AshMetrics.observe_elapsed/2`, which
are atomic on their own. A condition over the action name or an argument
leaves the action atomic.

The changes read every other tag from the record: the attribute, calculation
or aggregate of the same name, or the `path:` the tag declares. A closed tag
on such a counter must name one of those or declare a path, or no emission
from a change could ever carry it, and a verifier rejects the resource. The
attribute the change counts must be an attribute, never a calculation or an
aggregate. A tag whose value on the record is `nil`, a map or a struct is
left off the emission.

A tag naming a calculation or an aggregate makes the change load it for every
record it emits for, bulk actions included, with `authorize?: false` and the
changeset's tenant: each emission pays one extra load, and the tag can carry
a value the actor may not read. A calculation is loaded without arguments, so
give every argument it takes a default; a verifier rejects one with an
argument that is `allow_nil? false` and has no default. The value is read
when the change emits; inside an open transaction it includes that
transaction's uncommitted writes. The record the action returns does not
carry it; load it yourself when the caller needs it.

The load passes no actor and none of the changeset's context, so a
calculation reading `^actor(...)` or `^context(...)` sees `nil`; never tag
with one. A `sum`, `max`, `min`, `first` or `avg` aggregate over no related
rows is `nil` unless it declares `default:`, and its tag is left off. Give
such an aggregate a `default:` before closing its tag, or every emission for
a record without related rows is logged and lost.

The changes may sit on create, update and destroy actions. On a destroy
that is not `soft? true`, tag the metric from attributes only: the row is
deleted before the change emits, so an aggregate, or a calculation reading
related data, is not loaded or loads as `nil`, and its tag is left off; a
verifier rejects a tag naming a calculation or an aggregate there.
`AshMetrics.increment_on_change/2` on a destroy counts only when the destroy
writes the attribute a new value.

When the attribute `AshMetrics.increment_on_change/2` or
`AshMetrics.increment_on_write/2` counts holds a value its closed tag does not
declare, the change **skips the emission silently**: nothing is counted and
nothing is logged. Enumerate every value the attribute can hold, or the
counter quietly undercounts.

Every other rejected emission from a change is logged, not raised, bar the
one the next paragraph names. A closed tag read from the record holding an
undeclared value, or left off because it is `nil`, makes
`AshMetrics.increment/3` or `AshMetrics.observe/4` raise `ArgumentError`
inside the change; so does anything else that raises, throws or exits while
a change emits, such as a failing custom tag extractor or, with no
transaction open, a calculation that fails to load. The change logs it at
error level as `AshMetrics did not emit ...` with the resource, the action
and the metric, emits nothing, and leaves the action's result alone. Called
by hand, the same two functions raise to the caller.

A calculation or aggregate a tag names that fails to load while a
transaction is open is not logged: it rolls that transaction back. The call
that opened the transaction returns `{:error, %Ash.Error.Unknown{}}` holding
an `AshMetrics.Changes.TagLoadError`, and nothing written within the
transaction persists, bulk actions included. Tag only with calculations and
aggregates that cannot fail on the data the action writes.

A custom tag extractor that fails is logged even while a transaction is
open, and nothing rolls back. A query it runs that fails inside an open
transaction may already have aborted that transaction: the action still
reports success, and the surrounding transaction then fails at its next
statement or at commit, losing the action's write. Keep any query an
extractor runs one that cannot fail, or derive its tags from the metadata
alone.

An open tag filled this way carries whatever the row holds, one timeseries
per distinct value. Name a bounded field, or close it with `values:`;
never an identifier, a free-text column or anything a user typed.

The changes emit after the action's transaction commits, unless the
changeset is built inside a transaction that is already open, such as an
action called from another action's hook. Then they emit before that
transaction commits, and a later rollback does not retract the emission, not
even one caused by a later `after_action` hook failing the action itself; do
not expect a change's count to roll back with a surrounding transaction or
with the action.

Never count an action returning `{:ok, _}` as a business outcome. An ok tuple
means the function returned; the email being delivered, the invoice being
captured or the sync completing is a fact that usually arrives later, in a
notifier or a webhook. Count it there, with case 4.
