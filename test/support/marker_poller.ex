defmodule AshMetrics.Test.MarkerPoller do
  @moduledoc false
  # A poller that starts an Agent holding the gauges it was given, so that
  # `AshMetrics.Poller.child_specs/1` can be asserted to hand each poller its
  # own gauges only.

  @behaviour AshMetrics.Poller

  @impl AshMetrics.Poller
  @spec child_specs([AshMetrics.Poller.gauge()], keyword()) :: [Supervisor.child_spec()]
  def child_specs(gauges, opts) do
    [%{id: __MODULE__, start: {Agent, :start_link, [fn -> {gauges, opts} end]}}]
  end
end
