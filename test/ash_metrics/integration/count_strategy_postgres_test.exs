defmodule AshMetrics.Integration.CountStrategyPostgresTest do
  # Seeds a shared table in a real database, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias AshMetrics.Gauge.Runner
  alias AshMetrics.Gauge.Strategy.Count
  alias AshMetrics.Info
  alias AshMetrics.Test.PgJob
  alias AshMetrics.Test.Repo

  setup do
    Repo.delete_all(PgJob)
    on_exit(fn -> Repo.delete_all(PgJob) end)

    %{backlog: Info.metric!(PgJob, :backlog), total: Info.metric!(PgJob, :total)}
  end

  describe "compute/3" do
    test "counts every row matching the filter", %{total: total} do
      seed(status: :pending, provider: "ses")
      seed(status: :done, provider: "ses")

      assert Count.compute(PgJob, total, []) == {:ok, [{%{}, 2}]}
    end

    test "counts each group of rows matching the filter", %{backlog: backlog} do
      seed(status: :pending, provider: "ses")
      seed(status: :pending, provider: "ses")
      seed(status: :processing, provider: "smtp")
      seed(status: :done, provider: "ses")

      assert groups(Count.compute(PgJob, backlog, [])) == [
               {%{provider: "ses", status: :pending}, 2},
               {%{provider: "smtp", status: :processing}, 1}
             ]
    end

    # `provider == nil` is unknown rather than true in SQL, exactly as it is in
    # Ash, so the strategy asks for such a group with `is_nil` instead. This is
    # the assertion ETS cannot make: its filter engine compares in Elixir.
    test "counts a group whose value is nil", %{backlog: backlog} do
      seed(status: :pending, provider: nil)
      seed(status: :pending, provider: nil)
      seed(status: :pending, provider: "ses")

      assert groups(Count.compute(PgJob, backlog, [])) == [
               {%{provider: nil, status: :pending}, 2},
               {%{provider: "ses", status: :pending}, 1}
             ]
    end

    test "returns no groups at all for an empty table", %{backlog: backlog} do
      assert Count.compute(PgJob, backlog, []) == {:ok, []}
    end
  end

  describe "emit/3" do
    setup do
      handler = {__MODULE__, System.unique_integer([:positive])}
      event = AshMetrics.event_name(PgJob, :backlog)
      test = self()

      :telemetry.attach(
        handler,
        event,
        fn ^event, measurements, metadata, _config ->
          send(test, {:emitted, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "emits one measurement per group, including the nil one", %{backlog: backlog} do
      seed(status: :pending, provider: nil)
      seed(status: :processing, provider: "ses")

      assert {:ok, emitted} = Runner.emit(PgJob, backlog, [])

      assert Enum.sort(emitted) == [
               %{provider: nil, status: :pending},
               %{provider: "ses", status: :processing}
             ]

      assert_receive {:emitted, %{value: 1}, %{provider: nil, status: :pending}}
      assert_receive {:emitted, %{value: 1}, %{provider: "ses", status: :processing}}
    end

    test "zeroes a group that has drained", %{backlog: backlog} do
      seed(status: :pending, provider: "ses")

      assert {:ok, groups} = Runner.emit(PgJob, backlog, [])
      assert_receive {:emitted, %{value: 1}, %{provider: "ses", status: :pending}}

      Repo.delete_all(PgJob)

      assert Runner.emit(PgJob, backlog, groups) == {:ok, []}
      assert_receive {:emitted, %{value: 0}, %{provider: "ses", status: :pending}}
    end
  end

  defp seed(attrs), do: Ash.create!(PgJob, Map.new(attrs), authorize?: false)

  defp groups({:ok, groups}), do: Enum.sort(groups)
end
