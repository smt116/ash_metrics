defmodule AshMetrics.Poller.GenServer do
  @moduledoc """
  Polls every gauge from one process, on a timer per gauge.

  The default poller. It needs no job queue, no extra dependency and no
  configuration beyond being started. One process holds one timer per gauge,
  polls the gauge when it fires, and schedules the next poll `period`
  milliseconds later. The first poll of every gauge happens as soon as the
  process starts.

  ## What it does not do

  Every node polls. In a cluster of five nodes, every gauge is computed and
  emitted five times per period, which costs five times the queries and gives
  a reporter five identical measurements to aggregate. `last_value` tolerates
  that, but the queries are not free; `AshMetrics.Poller.AshOban` polls once
  per period for the whole cluster instead.

  A failed poll is not retried: it is logged, and the gauge is polled again at
  its next period. Neither an error from a strategy nor an exception inside
  one takes the process down, so one broken gauge cannot stop the others.
  """

  @behaviour AshMetrics.Poller

  use GenServer

  require Logger

  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Poller

  @typedoc "Each gauge being polled, by index: what to poll, and what it last found."
  @opaque state :: %{non_neg_integer() => {module(), Gauge.t(), [AshMetrics.tags()]}}

  @impl AshMetrics.Poller
  @spec child_specs([Poller.gauge()], keyword()) :: [Supervisor.child_spec()]
  def child_specs(gauges, opts \\ []) do
    [%{id: __MODULE__, start: {__MODULE__, :start_link, [[gauges: gauges] ++ opts]}}]
  end

  @doc """
  Starts the poller.

  ## Options

  * `:gauges` — required. The gauges to poll, as `{resource, gauge}` tuples.
  * `:name` — a name to register the process under.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gauges, opts} = Keyword.pop!(opts, :gauges)

    GenServer.start_link(__MODULE__, gauges, Keyword.take(opts, [:name]))
  end

  @impl GenServer
  @spec init([Poller.gauge()]) :: {:ok, state()}
  def init(gauges) do
    state =
      gauges
      |> Enum.with_index()
      |> Map.new(fn {{resource, gauge}, index} ->
        schedule(index, 0)

        {index, {resource, gauge, []}}
      end)

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:poll, index}, state) do
    {resource, gauge, known_groups} = Map.fetch!(state, index)
    groups = poll(resource, gauge, known_groups)

    schedule(index, gauge.period)

    {:noreply, Map.put(state, index, {resource, gauge, groups})}
  end

  @spec schedule(non_neg_integer(), non_neg_integer()) :: reference()
  defp schedule(index, period), do: Process.send_after(self(), {:poll, index}, period)

  # Returns the groups to remember: the ones this poll found, or the ones the
  # last successful poll found when it failed, so that a group is still zeroed
  # once it vanishes even if a poll was lost in between.
  @spec poll(module(), Gauge.t(), [AshMetrics.tags()]) :: [AshMetrics.tags()]
  defp poll(resource, gauge, known_groups) do
    case Runner.emit(resource, gauge, known_groups) do
      {:ok, groups} -> groups
      {:error, error} -> failed(resource, gauge, error, known_groups)
    end
  rescue
    exception -> failed(resource, gauge, exception, known_groups)
  catch
    kind, reason -> failed(resource, gauge, {kind, reason}, known_groups)
  end

  @spec failed(module(), Gauge.t(), term(), [AshMetrics.tags()]) :: [AshMetrics.tags()]
  defp failed(resource, gauge, error, known_groups) do
    Logger.error(
      "AshMetrics could not poll the gauge #{inspect(gauge.name)} on " <>
        "#{inspect(resource)}: #{inspect(error)}. It will be polled again in " <>
        "#{gauge.period}ms."
    )

    known_groups
  end
end
