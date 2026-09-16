defmodule AshMetrics do
  @moduledoc """
  Declarative business metrics for Ash resources.

  `AshMetrics` will add a `metrics do` block to an Ash resource, where counters,
  gauges and distributions are declared next to the action they describe and
  validated at compile time. Those declarations compile to `Telemetry.Metrics`
  definitions rather than to a new emit/aggregate/export pipeline, so the host
  application's existing reporter is what actually ships them to a backend.

  This module is currently documentation only; the DSL is not implemented yet.
  """
end
