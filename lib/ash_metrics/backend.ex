defmodule AshMetrics.Backend do
  @moduledoc """
  Optionally starts a reporter, and optionally rewrites the metric definitions.

  Configure one with:

      config :ash_metrics, backend: AshMetrics.Backend.Noop

  A backend that returns `:ignore` from `c:child_spec/1` starts nothing, which
  is the normal case for an application that already runs a reporter and only
  wants to splice `AshMetrics.metrics/0` into it.

  `AshMetrics.child_specs/1` starts these children along with the poller's; a
  host application normally calls that rather than `child_specs/1` here.
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

  @doc """
  Whether the backend computes and reports the declared gauges itself.

  Optional, defaulting to `false`. `AshMetrics.child_specs/1` starts no
  poller's children at all for a backend that returns `true`, whatever its
  `:poll` option says.
  """
  @callback polls_gauges?() :: boolean()

  @doc """
  Takes the result of one successful poll of one gauge.

  Optional. A backend that implements it is handed every successful poll the
  configured `AshMetrics.Poller` makes, in the process that ran the poll,
  instead of the `:telemetry` events `AshMetrics.Gauge.Runner.emit/3` would
  otherwise execute. `groups` is what `AshMetrics.Gauge.Runner.poll/2`
  returns: one `{tags, value}` tuple per group of this poll.

  A failed poll is not reported, and no group is zeroed on the backend's
  behalf; a group that was reported before and is absent from `groups` is the
  backend's to handle.
  """
  @callback report_gauge(
              resource :: module(),
              gauge :: AshMetrics.Dsl.Gauge.t(),
              groups :: [AshMetrics.Gauge.Strategy.group()]
            ) :: :ok

  @optional_callbacks transform_metrics: 2, polls_gauges?: 0, report_gauge: 3

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

  @doc """
  Whether the configured backend reports the declared gauges itself.

  `false` for a backend that does not implement `c:polls_gauges?/0`.
  """
  @spec polls_gauges?() :: boolean()
  def polls_gauges? do
    backend = Config.backend()

    Code.ensure_loaded?(backend) and function_exported?(backend, :polls_gauges?, 0) and
      backend.polls_gauges?()
  end

  @doc """
  Whether the configured backend takes the gauge values a poll collects.

  `false` for a backend that does not implement `c:report_gauge/3`.
  """
  @spec reports_gauges?() :: boolean()
  def reports_gauges? do
    backend = Config.backend()

    Code.ensure_loaded?(backend) and function_exported?(backend, :report_gauge, 3)
  end
end
