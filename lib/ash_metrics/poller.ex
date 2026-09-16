defmodule AshMetrics.Poller do
  @moduledoc """
  Decides when every declared gauge is polled.

  A gauge is the one primitive that has to be driven by something, and what
  should drive it depends on the application. The bundled
  `AshMetrics.Poller.GenServer` is one process per node with a timer per gauge,
  which needs nothing and suits most applications. An application that already
  runs a job queue may prefer to poll from it instead, so that exactly one node
  polls and a failed poll is retried and visible.

  Configure one with:

      config :ash_metrics, poller: AshMetrics.Poller.GenServer

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

  Called once, with every gauge of the application, so that a poller is free to
  run them all in one process, one process each, or nothing at all. `opts` are
  the options passed to `child_specs/1`.
  """
  @callback child_specs(gauges :: [gauge()], opts :: keyword()) :: [Supervisor.child_spec()]

  @doc """
  The child specifications to add to a supervision tree for the configured
  poller.

  Every gauge of every resource reachable from the configured
  `AshMetrics.Config.otp_app!/0` is discovered, exactly as `AshMetrics.metrics/0`
  discovers metrics, and handed to the poller in one go.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    Config.poller().child_specs(gauges(), opts)
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
