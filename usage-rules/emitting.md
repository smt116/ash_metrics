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

The changes and the hand-written API disagree about a bad closed-tag value.
A change reads the value off the written record and **skips the emission
silently** when the counter does not declare it; `AshMetrics.increment/3` and
`AshMetrics.observe/4` raise `ArgumentError` instead. Enumerate every value
the attribute can hold, or the counter quietly undercounts.

The changes read every other tag off the record: an attribute of the same
name, or the `path:` the tag declares. A closed tag on such a counter must be
one or the other, or no emission from a change could ever carry it, and a
verifier rejects the resource. A tag whose value on the record is `nil`, a
map or a struct is left off the emission.

An open tag filled this way carries whatever the row holds, one timeseries
per distinct value. Name a bounded attribute, or close it with `values:`;
never an identifier, a free-text column or anything a user typed.

Never count an action returning `{:ok, _}` as a business outcome. An ok tuple
means the function returned; the email being delivered, the invoice being
captured or the sync completing is a fact that usually arrives later, in a
notifier or a webhook. Count it there, with case 4.
