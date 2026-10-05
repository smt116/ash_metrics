defmodule AshMetrics.Gauge.Strategy.OldestAgeTest.Stamp do
  @moduledoc false
  # A timestamp behind an `Ash.Type.NewType`.
  use Ash.Type.NewType, subtype_of: :utc_datetime
end

defmodule AshMetrics.Gauge.Strategy.OldestAgeTest do
  # Seeds shared ETS tables and captures the compiler's stderr, so it cannot
  # run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Gauge.Strategy.OldestAge
  alias AshMetrics.Info
  alias AshMetrics.Test.AgedJob
  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.Ets
  alias Spark.Error.DslError

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    %{
      backlog_age: Info.metric!(AgedJob, :backlog_age),
      queue_age: Info.metric!(AgedJob, :queue_age)
    }
  end

  describe "compute/3 with group_by" do
    test "reports the age of each group's oldest row", %{backlog_age: gauge} do
      seed(status: :pending, provider: "ses", inserted_at: ago(300))
      seed(status: :pending, provider: "ses", inserted_at: ago(60))
      seed(status: :processing, provider: "smtp", inserted_at: ago(120))
      seed(status: :done, provider: "ses", inserted_at: ago(900))

      assert [
               {%{provider: "ses", status: :pending}, pending},
               {%{provider: "smtp", status: :processing}, processing}
             ] = groups(OldestAge.compute(AgedJob, gauge, []))

      assert pending in 300..301
      assert processing in 120..121
    end

    test "reports a group whose value is nil", %{backlog_age: gauge} do
      seed(status: :pending, provider: nil, inserted_at: ago(60))

      assert [{%{provider: nil, status: :pending}, age}] =
               groups(OldestAge.compute(AgedJob, gauge, []))

      assert age in 60..61
    end

    test "returns no groups at all for an empty table", %{backlog_age: gauge} do
      assert OldestAge.compute(AgedJob, gauge, []) == {:ok, []}
    end

    test "reads 0 for a row written after the poll", %{backlog_age: gauge} do
      seed(status: :pending, provider: "ses", inserted_at: ago(-600))

      assert OldestAge.compute(AgedJob, gauge, []) ==
               {:ok, [{%{provider: "ses", status: :pending}, 0}]}
    end
  end

  describe "compute/3 without group_by" do
    test "measures from the attribute named by the option", %{queue_age: gauge} do
      seed(status: :pending, inserted_at: ago(900), queued_at: naive_ago(240))
      seed(status: :processing, inserted_at: ago(900), queued_at: naive_ago(30))
      seed(status: :done, inserted_at: ago(900), queued_at: naive_ago(3_600))

      assert {:ok, [{%{}, age}]} = OldestAge.compute(AgedJob, gauge, [])
      assert age in 240..241
    end

    test "ignores rows whose attribute is nil", %{queue_age: gauge} do
      seed(status: :pending, queued_at: nil)
      seed(status: :pending, queued_at: naive_ago(45))

      assert {:ok, [{%{}, age}]} = OldestAge.compute(AgedJob, gauge, [])
      assert age in 45..46
    end

    test "reads 0 when every matching row holds nil", %{queue_age: gauge} do
      seed(status: :pending, queued_at: nil)

      assert OldestAge.compute(AgedJob, gauge, []) == {:ok, [{%{}, 0}]}
    end

    test "reads 0 for an empty table", %{queue_age: gauge} do
      assert OldestAge.compute(AgedJob, gauge, []) == {:ok, [{%{}, 0}]}
    end
  end

  describe "verify/2" do
    test "accepts each timestamp type" do
      for type <- [
            :utc_datetime,
            :utc_datetime_usec,
            :naive_datetime,
            :datetime,
            AshMetrics.Gauge.Strategy.OldestAgeTest.Stamp
          ] do
        assert errors(
                 quote(do: gauge(:age, strategy: AshMetrics.Gauge.Strategy.OldestAge)),
                 [quote(do: attribute(:inserted_at, unquote(type)))]
               ) == [],
               "expected #{inspect(type)} to be accepted"
      end
    end

    test "rejects a resource without the default attribute" do
      assert [%DslError{path: [:metrics, :age]} = error] =
               errors(quote(do: gauge(:age, strategy: AshMetrics.Gauge.Strategy.OldestAge)))

      assert Exception.message(error) =~
               "it measures from :inserted_at, which is not an attribute of this resource"
    end

    test "rejects an attribute that is not a timestamp" do
      assert [%DslError{} = error] =
               errors(
                 quote do
                   gauge :age, strategy: {AshMetrics.Gauge.Strategy.OldestAge, attribute: :status}
                 end
               )

      assert Exception.message(error) =~ "it measures from :status, whose type Ash.Type.Atom"
    end

    test "rejects an unknown option" do
      assert [%DslError{} = error] =
               errors(
                 quote do
                   gauge :age,
                     strategy: {AshMetrics.Gauge.Strategy.OldestAge, attribute: :at, unit: :hour}
                 end
               )

      assert Exception.message(error) =~ "unknown option :unit"
    end

    test "rejects a data layer without a :min aggregate" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: gauge(:age, strategy: AshMetrics.Gauge.Strategy.OldestAge)),
                 [quote(do: attribute(:inserted_at, :utc_datetime_usec))],
                 Ash.DataLayer.Simple
               )

      assert Exception.message(error) =~
               "it reads an Ash :min aggregate, which this resource's data layer " <>
                 "Ash.DataLayer.Simple does not support"
    end

    test "accepts the attribute named by the option" do
      assert errors(
               quote do
                 gauge :age, strategy: {AshMetrics.Gauge.Strategy.OldestAge, attribute: :at}
               end,
               [quote(do: attribute(:at, :naive_datetime))]
             ) == []
    end
  end

  defp errors(declarations, attributes \\ [], data_layer \\ Ash.DataLayer.Ets) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end,
      [quote(do: attribute(:status, :atom))] ++ attributes,
      [],
      data_layer
    )
  end

  defp seed(attrs), do: Ash.create!(AgedJob, Map.new(attrs), authorize?: false)

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp naive_ago(seconds),
    do: seconds |> ago() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

  defp groups({:ok, groups}), do: Enum.sort(groups)
end
