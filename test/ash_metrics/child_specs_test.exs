defmodule AshMetrics.ChildSpecsTest.Reporter do
  @moduledoc false
  # A backend that starts something, so that the order of the two lists is
  # observable.

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  def child_spec(opts) do
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}
  end
end

defmodule AshMetrics.ChildSpecsTest do
  # Swaps the configured backend, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.ChildSpecsTest.Reporter
  alias AshMetrics.Poller

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

  test "is the poller alone for a backend that starts nothing" do
    assert AshMetrics.child_specs() == Poller.child_specs()
  end

  test "is the backend followed by the pollers" do
    Application.put_env(:ash_metrics, :backend, Reporter)

    assert [
             %{id: Reporter},
             %{id: AshMetrics.Poller.GenServer},
             %{id: AshMetrics.Test.MarkerPoller}
           ] = AshMetrics.child_specs()
  end

  test "passes its options to both" do
    Application.put_env(:ash_metrics, :backend, Reporter)

    assert [
             %{start: {Agent, :start_link, [state]}},
             %{start: {_poller, :start_link, [args]}} | _rest
           ] = AshMetrics.child_specs(name: :metrics)

    assert state.() == [name: :metrics]
    assert Keyword.fetch!(args, :name) == :metrics
  end

  test "returns specs a supervisor can actually start" do
    Application.put_env(:ash_metrics, :backend, Reporter)

    assert {:ok, supervisor} =
             Supervisor.start_link(AshMetrics.child_specs(), strategy: :one_for_one)

    assert [
             {AshMetrics.Test.MarkerPoller, _marker, :worker, _marker_modules},
             {AshMetrics.Poller.GenServer, _poller, :worker, _poller_modules},
             {Reporter, _agent, :worker, _agent_modules}
           ] =
             Supervisor.which_children(supervisor)

    Supervisor.stop(supervisor)
  end
end
