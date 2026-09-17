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
  alias AshMetrics.Test.GlobalTenantJob
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.MarkedJob
  alias AshMetrics.Test.MarkerPoller
  alias AshMetrics.Test.PgJob
  alias AshMetrics.Test.SchemaJob
  alias AshMetrics.Test.TenantJob

  setup do
    original = Application.get_env(:ash_metrics, :poller)
    otp_app = Application.get_env(:ash_metrics, :otp_app)

    on_exit(fn ->
      Application.put_env(:ash_metrics, :otp_app, otp_app)

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
               {GlobalTenantJob, :backlog},
               {SchemaJob, :backlog},
               {MarkedJob, :backlog},
               {PgJob, :backlog},
               {PgJob, :total}
             ]
    end

    test "finds no counter or distribution" do
      assert Enum.all?(Poller.gauges(), &match?({_resource, %AshMetrics.Dsl.Gauge{}}, &1))
    end
  end

  describe "child_specs/1" do
    test "asks the default poller to poll every gauge that did not override it" do
      assert [
               %{id: AshMetrics.Poller.GenServer, start: {_module, :start_link, [args]}},
               %{id: MarkerPoller}
             ] = Poller.child_specs()

      assert Keyword.fetch!(args, :gauges) == default_gauges()
    end

    test "asks an overriding poller for that resource's gauges alone" do
      assert [_default, %{id: MarkerPoller, start: {Agent, :start_link, [state]}}] =
               Poller.child_specs()

      assert {[{MarkedJob, gauge}], []} = state.()
      assert gauge.name == :backlog
    end

    test "concatenates the pollers in a stable order" do
      Application.put_env(:ash_metrics, :poller, Manual)

      assert Enum.map(Poller.child_specs(), & &1.id) == [Manual, MarkerPoller]
    end

    test "passes its options to every poller" do
      Application.put_env(:ash_metrics, :poller, Manual)

      assert [
               %{id: Manual, start: {Agent, :start_link, [default]}},
               %{id: MarkerPoller, start: {Agent, :start_link, [marked]}}
             ] = Poller.child_specs(name: :polling)

      assert {gauges, [name: :polling]} = default.()
      assert gauges == default_gauges()
      assert {[{MarkedJob, _gauge}], [name: :polling]} = marked.()
    end

    test "asks the configured poller alone when nothing declares a gauge" do
      Application.put_env(:ash_metrics, :poller, Manual)
      Application.put_env(:ash_metrics, :otp_app, :telemetry)

      assert [%{id: Manual, start: {Agent, :start_link, [state]}}] = Poller.child_specs()
      assert state.() == {[], []}
    end

    test "returns specs a supervisor can actually start" do
      assert {:ok, supervisor} =
               Supervisor.start_link(Poller.child_specs(), strategy: :one_for_one)

      assert [
               {MarkerPoller, marker, :worker, _marker_modules},
               {AshMetrics.Poller.GenServer, pid, :worker, _modules}
             ] = Supervisor.which_children(supervisor)

      assert is_pid(pid)
      assert is_pid(marker)

      Supervisor.stop(supervisor)
    end
  end

  defp default_gauges do
    Enum.reject(Poller.gauges(), fn {resource, _gauge} -> resource == MarkedJob end)
  end
end
