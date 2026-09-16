defmodule AshMetrics.PollerTest.Manual do
  @moduledoc false
  # A poller that starts nothing, to prove that the configured one is asked
  # and that it is given every gauge.

  @behaviour AshMetrics.Poller

  @impl AshMetrics.Poller
  def child_specs(gauges, opts) do
    [%{id: __MODULE__, start: {Agent, :start_link, [fn -> {gauges, opts} end]}}]
  end
end

defmodule AshMetrics.PollerTest do
  # Swaps the configured poller, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Poller
  alias AshMetrics.PollerTest.Manual
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.SchemaJob
  alias AshMetrics.Test.TenantJob

  setup do
    original = Application.get_env(:ash_metrics, :poller)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, :poller)
        poller -> Application.put_env(:ash_metrics, :poller, poller)
      end
    end)

    :ok
  end

  describe "gauges/0" do
    test "finds every gauge of every resource of the configured application" do
      assert Enum.map(Poller.gauges(), fn {resource, gauge} -> {resource, gauge.name} end) == [
               {Job, :backlog},
               {Job, :total},
               {TenantJob, :backlog},
               {SchemaJob, :backlog}
             ]
    end

    test "finds no counter or distribution" do
      assert Enum.all?(Poller.gauges(), &match?({_resource, %AshMetrics.Dsl.Gauge{}}, &1))
    end
  end

  describe "child_specs/1" do
    test "asks the default poller to poll every gauge in one process" do
      assert [%{id: AshMetrics.Poller.GenServer, start: {_module, :start_link, [args]}}] =
               Poller.child_specs()

      assert Keyword.fetch!(args, :gauges) == Poller.gauges()
    end

    test "passes its options to the poller" do
      Application.put_env(:ash_metrics, :poller, Manual)

      assert [%{start: {Agent, :start_link, [state]}}] = Poller.child_specs(name: :polling)

      assert {gauges, [name: :polling]} = state.()
      assert gauges == Poller.gauges()
    end

    test "returns a spec a supervisor can actually start" do
      assert {:ok, supervisor} =
               Supervisor.start_link(Poller.child_specs(), strategy: :one_for_one)

      assert [{AshMetrics.Poller.GenServer, pid, :worker, _modules}] =
               Supervisor.which_children(supervisor)

      assert is_pid(pid)

      Supervisor.stop(supervisor)
    end
  end
end
