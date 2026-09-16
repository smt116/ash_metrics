defmodule AshMetrics.Backend.Noop do
  @moduledoc """
  A backend that starts nothing. The default.

  This is the right choice in two situations. The first is an application that
  already runs a reporter: it splices `AshMetrics.metrics/0` into that
  reporter's own metric list, and there is nothing for a backend to start. The
  second is development, where there is usually no collector listening and a
  reporter that keeps failing to reach one is pure noise.

  "Noop" rather than "None" or "Null": OpenTelemetry spells it this way
  (`otel_tracer_noop`, `otel_meter_noop`), `None` reads like configuration
  somebody forgot to fill in rather than a decision, and `Null` collides with
  `nil` being Elixir's actual null.
  """

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  @spec child_spec(keyword()) :: :ignore
  def child_spec(_opts), do: :ignore
end
