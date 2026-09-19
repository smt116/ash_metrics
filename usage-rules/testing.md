<!--
SPDX-FileCopyrightText: 2026 Maciej Malecki

SPDX-License-Identifier: MIT
-->

# Testing emissions

`use AshMetrics.Test` after `use ExUnit.Case`. It attaches a handler for the
duration of each test and imports the assertions.

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

`:telemetry` handlers are global, so keep such modules `async: false`, or
narrow the attachment with `resources:` to metrics no async test emits:

```elixir
use AshMetrics.Test, resources: [MyApp.Mailings.TemplatedDelivery]
```

## The assertions

`assert_metric_emitted/2` and `refute_metric_emitted/2` take the metric name
as the declaration produces it, **without** the `.count`, `.gauge` or
`.duration` suffix a reporter appends.

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

To exercise a gauge, either pass `poll: true` to `AshMetrics.Supervisor` in
that one test, or skip the poller entirely and call
`AshMetrics.Gauge.Runner.emit/3` directly.

A test that exercises `AshMetrics.Poller.AshOban` needs a real database:
Oban's cron inserts jobs into it.
