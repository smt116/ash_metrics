<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Testing emissions

`use AshMetrics.Test` after `use ExUnit.Case`. It attaches a handler for the
duration of each test and imports the assertions.

```elixir
defmodule MyApp.MailingsTest do
  use ExUnit.Case, async: true
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

A test receives an emission only when the emitting process, or a process in
its `$callers`, is the test process or one passed to `allow/1`. Emissions from
the test process and from the `Task`s it starts arrive, so these modules can
be `async: true`. An emission from any other process, such as a GenServer, a
supervised worker or an Oban job not run inline, is dropped silently. Fix it in
one of two ways:

- Call `allow/1` with that process's pid from the test, before it emits.
- `use AshMetrics.Test, shared: true` to receive every emission from every
  process. Such a module must be `async: false`.

Pass `resources:` to attach only to some resources' metrics:

```elixir
use AshMetrics.Test, resources: [MyApp.Mailings.TemplatedDelivery]
```

## The assertions

`assert_metric_emitted/2` and `refute_metric_emitted/2` take the metric name
as the declaration produces it, **without** the aggregation suffix a reporter
appends.

- `tags:` — a map or a keyword list, matched as a subset. An emission
  carrying tags the assertion says nothing about still matches.
- `value:` — the observed value of a distribution.

`assert_metric_emitted/2` returns the measurements and tags it matched.
Emissions of other names are left in the mailbox, so several assertions can
be made in any order.

## Gauges in tests

Keep `poll: false` in `config/test.exs`, which is what the installer writes;
otherwise every gauge is polled against the test database from the moment the
supervisor starts.

To exercise a gauge, call `AshMetrics.Gauge.Runner.emit/3` from the test
process. Passing `poll: true` to `AshMetrics.Supervisor` instead polls from
the poller's own process, which the test does not own, so its emissions arrive
only after `allow/1` with the poller's pid, or with `shared: true`.

A test that exercises `AshMetrics.Poller.AshOban` needs a real database:
Oban's cron inserts jobs into it. Run the jobs with `Oban.drain_queue/2` from
the test process, or use `shared: true`.
