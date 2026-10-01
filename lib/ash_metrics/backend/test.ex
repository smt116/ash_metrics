defmodule AshMetrics.Backend.Test do
  @moduledoc """
  A backend that forwards emissions to a test process's mailbox.

  It starts nothing; what it adds is `attach/3`, which subscribes a process to
  the `:telemetry` events behind a list of metric definitions and forwards each
  one as a message:

      {:ash_metrics, name, measurements, metadata}

  `name` is the metric name without its aggregation suffix: the name a
  declaration produces, not the suffixed variant a reporter publishes.

  An attachment forwards only the emissions of processes the attached process
  owns, or every emission when attached with `shared: true`;
  `AshMetrics.Test` documents the ownership rule.

  `AshMetrics.Test` wires all of this up, and is what a test suite should use;
  reach for this module directly only when the assertion helpers are not what
  you want.
  """

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  @spec child_spec(keyword()) :: :ignore
  def child_spec(_opts), do: :ignore

  @doc """
  Forwards the emissions behind `metrics` to `pid`, which defaults to the
  calling process.

  ## Options

  * `:shared` — forward every emission, from any process. Defaults to
    `false`.

  Attaching twice for the same process fails; call `detach/1` between.
  """
  @spec attach([Telemetry.Metrics.t()], pid(), keyword()) :: :ok | {:error, :already_exists}
  def attach(metrics, pid \\ self(), opts \\ []) when is_pid(pid) do
    opts = Keyword.validate!(opts, shared: false)
    names = Map.new(metrics, &{&1.event_name, base_name(&1)})

    attach_handler(pid, Map.keys(names), %{
      pid: pid,
      names: names,
      shared: Keyword.fetch!(opts, :shared),
      allowed: []
    })
  end

  @doc """
  Forwards to `owner` the emissions of `pid` and of the processes whose
  `$callers` include it.

  Raises `ArgumentError` when nothing is attached for `owner`. Re-attaches
  `owner`'s handler, so an emission made by another process while this runs
  may be missed. Concurrent calls for the same `owner` are not supported.
  """
  @spec allow(pid(), pid()) :: :ok
  def allow(owner, pid) when is_pid(owner) and is_pid(pid) do
    id = handler_id(owner)

    case Enum.filter(:telemetry.list_handlers([]), &(&1.id == id)) do
      [] ->
        raise ArgumentError,
              "cannot allow #{inspect(pid)}: nothing is attached for #{inspect(owner)}"

      [%{config: config} | _rest] = handlers ->
        _ = :telemetry.detach(id)

        :ok =
          attach_handler(
            owner,
            Enum.map(handlers, & &1.event_name),
            %{config | allowed: Enum.uniq([pid | config.allowed])}
          )
    end
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
  def handle_event(event_name, measurements, metadata, %{pid: pid, names: names} = config) do
    if forward?(config) do
      send(pid, {:ash_metrics, Map.fetch!(names, event_name), measurements, metadata})
    end

    :ok
  end

  # The handler runs in the emitting process.
  @spec forward?(map()) :: boolean()
  defp forward?(%{shared: true}), do: true

  defp forward?(%{pid: owner, allowed: allowed}) do
    owners = [owner | allowed]

    Enum.any?([self() | Process.get(:"$callers", [])], &(&1 in owners))
  end

  @spec attach_handler(pid(), [[atom()]], map()) :: :ok | {:error, :already_exists}
  defp attach_handler(pid, event_names, config) do
    :telemetry.attach_many(handler_id(pid), event_names, &__MODULE__.handle_event/4, config)
  end

  @spec handler_id(pid()) :: term()
  defp handler_id(pid), do: {__MODULE__, pid}

  @spec base_name(Telemetry.Metrics.t()) :: String.t()
  defp base_name(metric) do
    metric.name |> Enum.drop(-1) |> Enum.map_join(".", &Atom.to_string/1)
  end
end
