defmodule AshMetrics.SupervisorTest.Reporter do
  @moduledoc false
  # A backend that starts something, so that the supervisor has a child which
  # is not a poller.

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  def child_spec(opts) do
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}
  end
end

defmodule AshMetrics.SupervisorTest do
  # Swaps the configured backend, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.SupervisorTest.Reporter

  setup do
    original = Application.get_env(:ash_metrics, :backend)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, :backend)
        backend -> Application.put_env(:ash_metrics, :backend, backend)
      end
    end)

    :ok
  end

  defp ids(supervisor) do
    supervisor |> Supervisor.which_children() |> Enum.map(fn {id, _pid, _type, _mods} -> id end)
  end

  test "starts under its own name" do
    pid = start_supervised!(AshMetrics.Supervisor)

    assert Process.whereis(AshMetrics.Supervisor) == pid
  end

  test "supervises the pollers of the declared gauges" do
    pid = start_supervised!(AshMetrics.Supervisor)

    assert AshMetrics.Poller.GenServer in ids(pid)
  end

  test "supervises the backend's children as well" do
    Application.put_env(:ash_metrics, :backend, Reporter)

    pid = start_supervised!(AshMetrics.Supervisor)

    assert Reporter in ids(pid)
    assert AshMetrics.Poller.GenServer in ids(pid)
  end

  test "supervises exactly what child_specs/1 returns" do
    Application.put_env(:ash_metrics, :backend, Reporter)

    pid = start_supervised!(AshMetrics.Supervisor)

    assert Enum.sort(ids(pid)) ==
             AshMetrics.child_specs() |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "supervises the backend alone when polling is off" do
    Application.put_env(:ash_metrics, :backend, Reporter)

    pid = start_supervised!({AshMetrics.Supervisor, poll: false})

    assert ids(pid) == [Reporter]
  end

  test "registers under an explicit name" do
    pid = start_supervised!({AshMetrics.Supervisor, name: AshMetrics.SupervisorTest.Named})

    assert Process.whereis(AshMetrics.SupervisorTest.Named) == pid
    refute Process.whereis(AshMetrics.Supervisor)
  end
end
