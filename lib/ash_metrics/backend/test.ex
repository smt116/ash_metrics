defmodule AshMetrics.Backend.Test do
  @moduledoc """
  A backend that forwards emissions to a test process's mailbox.

  It starts nothing; what it adds is `attach/2`, which subscribes a process to
  the `:telemetry` events behind a list of metric definitions and forwards each
  one as a message:

      {:ash_metrics, name, measurements, metadata}

  `name` is the metric name without its aggregation suffix: the name a
  declaration produces, not the `.count` or `.duration` variant a reporter
  publishes.

  Handlers are keyed by the receiving process, so each test attaches and
  detaches its own. `:telemetry` handlers are still global: an attachment is
  invoked for an emission from any process. See `AshMetrics.Test` on keeping
  such modules `async: false`.

  `AshMetrics.Test` wires all of this up, and is what a test suite should use;
  reach for this module directly only when the assertion helpers are not what
  you want.
  """

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  @spec child_spec(keyword()) :: :ignore
  def child_spec(_opts), do: :ignore

  @doc """
  Forwards every emission behind `metrics` to `pid`, which defaults to the
  calling process.

  Attaching twice for the same process fails; call `detach/1` between.
  """
  @spec attach([Telemetry.Metrics.t()], pid()) :: :ok
  def attach(metrics, pid \\ self()) do
    names = Map.new(metrics, &{&1.event_name, base_name(&1)})

    :telemetry.attach_many(
      handler_id(pid),
      Map.keys(names),
      &__MODULE__.handle_event/4,
      %{pid: pid, names: names}
    )
  end

  @doc """
  Stops forwarding emissions to a process.

  Takes the process, or the list of metrics it was attached with, in which case
  the calling process is detached. Detaching when nothing is attached is not an
  error.
  """
  @spec detach([Telemetry.Metrics.t()] | pid()) :: :ok
  def detach(metrics_or_pid \\ self())

  def detach(pid) when is_pid(pid) do
    # `:telemetry.detach/1` reports a handler that was never attached, which is
    # not something a test teardown needs to care about.
    _ = :telemetry.detach(handler_id(pid))

    :ok
  end

  def detach(metrics) when is_list(metrics), do: detach(self())

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event_name, measurements, metadata, %{pid: pid, names: names}) do
    send(pid, {:ash_metrics, Map.fetch!(names, event_name), measurements, metadata})

    :ok
  end

  @spec handler_id(pid()) :: term()
  defp handler_id(pid), do: {__MODULE__, pid}

  @spec base_name(Telemetry.Metrics.t()) :: String.t()
  defp base_name(metric) do
    metric.name |> Enum.drop(-1) |> Enum.map_join(".", &Atom.to_string/1)
  end
end
