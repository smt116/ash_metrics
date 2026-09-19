defmodule AshMetrics.Poller.AshOban.Emit do
  @moduledoc """
  The generic action behind one gauge scheduled on Oban.

  `AshMetrics.Poller.AshOban.Transformer` adds one action per gauge, all of
  them run by this module and told which gauge they are through the `gauge`
  option. There is nothing to call here by hand: `AshMetrics.Gauge.Runner` is
  the way to poll a gauge from code.

  A failed poll returns its error; `Ash.run_action!/1` inside AshOban's worker
  raises on it and the poll shows up as a failed Oban job.

  The groups each poll found are handed to `AshMetrics.Poller.AshOban.Memory`,
  from which the next poll zeroes the ones that have drained. A failed poll
  leaves that memory untouched.
  """

  use Ash.Resource.Actions.Implementation

  alias Ash.Resource.Actions.Implementation.Context
  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Info
  alias AshMetrics.Poller.AshOban.Memory

  @doc """
  Polls the gauge named by `opts[:gauge]` and emits one measurement per group.
  """
  @impl Ash.Resource.Actions.Implementation
  @spec run(Ash.ActionInput.t(), keyword(), Context.t()) :: :ok | {:error, term()}
  def run(input, opts, _context) do
    resource = input.resource
    name = Keyword.fetch!(opts, :gauge)
    gauge = Info.metric!(resource, name)

    case Runner.emit(resource, gauge, Memory.get(resource, name)) do
      {:ok, groups} -> Memory.put(resource, name, groups)
      {:error, error} -> {:error, error}
    end
  end
end
