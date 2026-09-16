defmodule AshMetrics.Backend do
  @moduledoc """
  Optionally starts a reporter, and optionally rewrites the metric definitions.

  A backend is thin on purpose. This package's output is the list of
  `Telemetry.Metrics` definitions from `AshMetrics.metrics/0`, and the
  established reporter ecosystem already ships those to StatsD, Prometheus,
  OTLP or anything else. A backend exists only so that an application which
  runs no reporter yet is not forced to wire one before it can see a metric,
  and so that one which does run a reporter can adapt the definitions to it.

  Configure one with:

      config :ash_metrics, backend: AshMetrics.Backend.Noop

  A backend that returns `:ignore` from `c:child_spec/1` starts nothing. That
  is the normal case for an application that already runs a reporter and only
  wants to splice `AshMetrics.metrics/0` into it.

  Splice `child_specs/1` into a supervision tree to start whatever the
  configured backend needs:

      children = [MyApp.Repo, MyAppWeb.Endpoint] ++ AshMetrics.Backend.child_specs()

      Supervisor.init(children, strategy: :one_for_one)
  """

  alias AshMetrics.Config

  @doc """
  The child specification of whatever the backend needs running, or `:ignore`
  when it needs nothing.

  `opts` are the options passed to `child_specs/1`.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec() | :ignore

  @doc """
  Rewrites the compiled metric definitions before they are handed to a
  reporter.

  Optional. Implement it when a backend needs to adapt the definitions —
  renaming, re-tagging, or attaching reporter options it alone understands.
  Called once, when the definitions are compiled, not per emission.
  """
  @callback transform_metrics([Telemetry.Metrics.t()], keyword()) :: [Telemetry.Metrics.t()]

  @optional_callbacks transform_metrics: 2

  @doc """
  The child specifications to add to a supervision tree for the configured
  backend.

  Returns `[]` when the backend returns `:ignore`, so the result can always be
  concatenated into a list of children without checking it first.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    case Config.backend().child_spec(opts) do
      :ignore -> []
      child_spec -> [child_spec]
    end
  end
end
