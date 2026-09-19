defmodule AshMetrics.BackendTest.Reporter do
  @moduledoc false
  # A backend that both starts something and adapts the definitions, which is
  # the shape of a real reporter-owning backend.

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  def child_spec(opts) do
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}
  end

  @impl AshMetrics.Backend
  def transform_metrics(metrics, opts) do
    Enum.map(metrics, &%{&1 | description: Keyword.get(opts, :description, "adapted")})
  end
end

defmodule AshMetrics.BackendTest.GaugeReporter do
  @moduledoc false
  # A backend that reports the gauges itself.

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  def child_spec(_opts), do: :ignore

  @impl AshMetrics.Backend
  def polls_gauges?, do: true
end

defmodule AshMetrics.BackendTest do
  # Swaps the configured backend, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Backend
  alias AshMetrics.BackendTest.GaugeReporter
  alias AshMetrics.BackendTest.Reporter
  alias AshMetrics.Test.Invoice

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

  describe "AshMetrics.Backend.Noop" do
    test "starts nothing" do
      assert Backend.Noop.child_spec([]) == :ignore
    end
  end

  describe "child_specs/1" do
    test "is empty for the default backend, so it can be concatenated safely" do
      assert Backend.child_specs() == []
      assert [:a] ++ Backend.child_specs() == [:a]
    end

    test "wraps the backend's child spec in a list" do
      Application.put_env(:ash_metrics, :backend, Reporter)

      assert [%{id: Reporter, start: {Agent, :start_link, [starter]}}] = Backend.child_specs()
      assert is_function(starter, 0)
    end

    test "passes its options to the backend" do
      Application.put_env(:ash_metrics, :backend, Reporter)

      assert [%{start: {Agent, :start_link, [starter]}}] = Backend.child_specs(port: 4242)
      assert starter.() == [port: 4242]
    end

    test "returns a spec a supervisor can actually start" do
      Application.put_env(:ash_metrics, :backend, Reporter)

      assert {:ok, supervisor} =
               Supervisor.start_link(Backend.child_specs(), strategy: :one_for_one)

      assert [{Reporter, pid, :worker, _modules}] = Supervisor.which_children(supervisor)
      assert is_pid(pid)

      Supervisor.stop(supervisor)
    end
  end

  describe "polls_gauges?/0" do
    test "is false for a backend that does not implement the callback" do
      Application.put_env(:ash_metrics, :backend, Reporter)

      refute Backend.polls_gauges?()
    end

    test "is false for the default backend" do
      refute Backend.polls_gauges?()
    end

    test "is what the backend says" do
      Application.put_env(:ash_metrics, :backend, GaugeReporter)

      assert Backend.polls_gauges?()
    end
  end

  describe "transform_metrics/2" do
    test "is applied to the compiled definitions" do
      Application.put_env(:ash_metrics, :backend, Reporter)

      assert Enum.map(AshMetrics.metrics_for([Invoice]), & &1.description) == [
               "adapted",
               "adapted"
             ]
    end

    test "is not required of a backend" do
      assert Enum.map(AshMetrics.metrics_for([Invoice]), & &1.description) == [nil, nil]
    end
  end
end
