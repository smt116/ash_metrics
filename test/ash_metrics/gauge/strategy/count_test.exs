defmodule AshMetrics.Gauge.Strategy.CountTest.Fixed do
  @moduledoc false
  # A custom strategy, to prove that the DSL takes a module and that the
  # resolution of `:count` is not the only path.

  @behaviour AshMetrics.Gauge.Strategy

  @impl AshMetrics.Gauge.Strategy
  def compute(_resource, _gauge, _opts), do: {:ok, [{%{status: :pending}, 7}]}
end

defmodule AshMetrics.Gauge.Strategy.CountTest do
  # Seeds shared ETS tables, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy.Count
  alias AshMetrics.Gauge.Strategy.CountTest.Fixed
  alias AshMetrics.Info
  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.SchemaJob

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    %{backlog: Info.metric!(Job, :backlog), total: Info.metric!(Job, :total)}
  end

  describe "compute/3 without group_by" do
    test "counts every row matching the filter", %{total: total} do
      seed(status: :pending)
      seed(status: :done)

      assert Count.compute(Job, total, []) == {:ok, [{%{}, 2}]}
    end

    test "returns one group of zero for an empty table", %{total: total} do
      assert Count.compute(Job, total, []) == {:ok, [{%{}, 0}]}
    end

    test "applies the gauge's filter", %{backlog: backlog} do
      seed(status: :pending)
      seed(status: :processing)
      seed(status: :done)

      assert Count.compute(Job, %{backlog | group_by: []}, []) == {:ok, [{%{}, 2}]}
    end
  end

  describe "compute/3 with group_by" do
    test "counts each group of rows matching the filter", %{backlog: backlog} do
      seed(status: :pending, provider: "ses")
      seed(status: :pending, provider: "ses")
      seed(status: :processing, provider: "smtp")
      seed(status: :done, provider: "ses")

      assert groups(Count.compute(Job, backlog, [])) == [
               {%{provider: "ses", status: :pending}, 2},
               {%{provider: "smtp", status: :processing}, 1}
             ]
    end

    test "counts every group when the gauge has no filter", %{backlog: backlog} do
      seed(status: :pending, provider: "ses")
      seed(status: :done, provider: "ses")

      assert groups(Count.compute(Job, %{backlog | filter: nil}, [])) == [
               {%{provider: "ses", status: :done}, 1},
               {%{provider: "ses", status: :pending}, 1}
             ]
    end

    test "counts a group whose value is nil", %{backlog: backlog} do
      seed(status: :pending, provider: nil)
      seed(status: :pending, provider: "ses")

      assert groups(Count.compute(Job, backlog, [])) == [
               {%{provider: nil, status: :pending}, 1},
               {%{provider: "ses", status: :pending}, 1}
             ]
    end

    test "returns no groups at all for an empty table", %{backlog: backlog} do
      assert Count.compute(Job, backlog, []) == {:ok, []}
    end

    test "returns no group for a value that no row has", %{backlog: backlog} do
      seed(status: :done, provider: "ses")

      assert Count.compute(Job, backlog, []) == {:ok, []}
    end
  end

  describe "compute/3 with a tenant" do
    test "counts only the rows of the given tenant" do
      backlog = Info.metric!(SchemaJob, :backlog)

      Ash.create!(SchemaJob, %{status: :pending}, tenant: "tenant_a", authorize?: false)
      Ash.create!(SchemaJob, %{status: :pending}, tenant: "tenant_b", authorize?: false)
      Ash.create!(SchemaJob, %{status: :processing}, tenant: "tenant_b", authorize?: false)

      assert Count.compute(SchemaJob, backlog, tenant: "tenant_a") ==
               {:ok, [{%{status: :pending}, 1}]}

      assert groups(Count.compute(SchemaJob, backlog, tenant: "tenant_b")) == [
               {%{status: :pending}, 1},
               {%{status: :processing}, 1}
             ]
    end
  end

  describe "strategy_module/1" do
    test "resolves the built-in :count", %{backlog: backlog} do
      assert Gauge.strategy_module(backlog) == Count
    end

    test "takes a declared strategy module as it is" do
      resource =
        Compiler.compile_resource(
          quote do
            metrics do
              gauge :backlog, strategy: AshMetrics.Gauge.Strategy.CountTest.Fixed
            end
          end
        )

      gauge = Info.metric!(resource, :backlog)

      assert Gauge.strategy_module(gauge) == Fixed
      assert Fixed.compute(resource, gauge, []) == {:ok, [{%{status: :pending}, 7}]}
    end
  end

  defp seed(attrs), do: Ash.create!(Job, Map.new(attrs), authorize?: false)

  defp groups({:ok, groups}), do: Enum.sort(groups)
end
