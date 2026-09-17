defmodule AshMetrics.Poller do
  @moduledoc """
  Decides when every declared gauge is polled.

  The bundled `AshMetrics.Poller.GenServer` is one process per node with a
  timer per gauge, and needs nothing configured. `AshMetrics.Poller.AshOban`
  polls from Oban's cron instead, once per period for the whole cluster.

  Configure one with:

      config :ash_metrics, poller: AshMetrics.Poller.GenServer

  A single resource may override it, which is how one backlog runs on a job
  queue while the rest run on the timer:

      metrics do
        poller AshMetrics.Poller.AshOban
      end

  Splice `child_specs/1` into a supervision tree to start it:

      children = [MyApp.Repo, MyAppWeb.Endpoint] ++ AshMetrics.Poller.child_specs()

  or use `AshMetrics.child_specs/1`, which adds the configured backend's
  children as well.
  """

  alias AshMetrics.Config
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Info

  @typedoc "A gauge, and the resource that declares it."
  @type gauge :: {module(), Gauge.t()}

  @doc """
  The child specifications that poll `gauges`.

  Called once, with every gauge of the application. A poller may run them all
  in one process, one process each, or nothing at all. `opts` are the options
  passed to `child_specs/1`.
  """
  @callback child_specs(gauges :: [gauge()], opts :: keyword()) :: [Supervisor.child_spec()]

  @doc """
  The child specifications to add to a supervision tree for every poller in
  use.

  Every gauge of every resource reachable from the configured
  `AshMetrics.Config.otp_app!/0` is grouped by the poller that
  `AshMetrics.Info.poller/1` says polls it. Each poller is asked once, for its
  own gauges only, and the results are concatenated in a stable order, by
  poller module name.

  An application that declares no gauges at all still gets the configured
  poller's children.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    gauges()
    |> by_poller()
    |> Enum.sort_by(fn {poller, _gauges} -> poller end)
    |> Enum.flat_map(fn {poller, gauges} -> poller.child_specs(gauges, opts) end)
  end

  @spec by_poller([gauge()]) :: %{module() => [gauge()]}
  defp by_poller(gauges) do
    case Enum.group_by(gauges, fn {resource, _gauge} -> Info.poller(resource) end) do
      grouped when map_size(grouped) == 0 -> %{Config.poller() => []}
      grouped -> grouped
    end
  end

  @doc """
  Every gauge of every resource of the configured application, with the
  resource that declares it.
  """
  @spec gauges() :: [gauge()]
  def gauges do
    Enum.flat_map(AshMetrics.resources(), fn resource ->
      resource
      |> Info.metrics()
      |> Enum.filter(&match?(%Gauge{}, &1))
      |> Enum.map(&{resource, &1})
    end)
  end
end
