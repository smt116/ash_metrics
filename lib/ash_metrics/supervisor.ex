defmodule AshMetrics.Supervisor do
  @moduledoc """
  Everything AshMetrics needs running, under one child.

  Supervises exactly what `AshMetrics.child_specs/1` returns — the configured
  `AshMetrics.Backend`'s children followed by every `AshMetrics.Poller` in use
  — with a `:one_for_one` strategy. Adding it to an application is equivalent
  to splicing that list in.

  Put it after the repository: a gauge is answered by a query.

      defmodule MyApp.Application do
        use Application

        @impl Application
        def start(_type, _args) do
          children = [
            MyApp.Repo,
            MyAppWeb.Endpoint,
            {Telemetry.Metrics.ConsoleReporter, metrics: AshMetrics.metrics()},
            AshMetrics.Supervisor
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  `:name` names this supervisor, as it does for any other child of a
  supervision tree; every other option is passed on to
  `AshMetrics.child_specs/1` and reaches the backend and the pollers.

  With the default `AshMetrics.Backend.Noop` and no gauges declared anywhere,
  the only thing under it is the timer poller's process, sitting idle.
  """

  use Supervisor

  @doc """
  Starts the supervisor.

  Registers it under `AshMetrics.Supervisor` unless `opts` carries a `:name`.
  The remaining options are passed to `AshMetrics.child_specs/1`; `:name` is
  not among them, since a poller registers itself under the `:name` it is
  given.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    Supervisor.init(AshMetrics.child_specs(opts), strategy: :one_for_one)
  end
end
