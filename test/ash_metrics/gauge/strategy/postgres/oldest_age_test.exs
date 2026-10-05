defmodule AshMetrics.Gauge.Strategy.Postgres.OldestAgeTest do
  # Captures the compiler's stderr, so it cannot run alongside other tests.
  # What the strategy computes is asserted against a database by
  # `AshMetrics.Integration.PostgresOldestAgeStrategyPostgresTest`.
  use ExUnit.Case, async: false

  alias AshMetrics.Test.Compiler
  alias Spark.Error.DslError

  describe "verify/2" do
    test "accepts a timestamp attribute of a resource on AshPostgres.DataLayer" do
      assert errors(
               quote do
                 gauge :age,
                   strategy: {AshMetrics.Gauge.Strategy.Postgres.OldestAge, attribute: :at}
               end,
               AshPostgres.DataLayer
             ) == []
    end

    test "rejects a resource on another data layer" do
      assert [%DslError{path: [:metrics, :age]} = error] =
               errors(
                 quote do
                   gauge :age,
                     strategy: {AshMetrics.Gauge.Strategy.Postgres.OldestAge, attribute: :at}
                 end,
                 Ash.DataLayer.Ets
               )

      assert Exception.message(error) =~
               "it queries through AshPostgres.DataLayer, and this resource uses " <>
                 "Ash.DataLayer.Ets"
    end

    test "rejects what OldestAge rejects" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: gauge(:age, strategy: AshMetrics.Gauge.Strategy.Postgres.OldestAge)),
                 AshPostgres.DataLayer
               )

      assert Exception.message(error) =~
               "it measures from :inserted_at, which is not an attribute of this resource"

      assert [%DslError{} = error] =
               errors(
                 quote do
                   gauge :age,
                     strategy:
                       {AshMetrics.Gauge.Strategy.Postgres.OldestAge, attribute: :at, unit: :hour}
                 end,
                 AshPostgres.DataLayer
               )

      assert Exception.message(error) =~ "unknown option :unit"
    end
  end

  defp errors(declarations, data_layer) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end,
      [quote(do: attribute(:at, :utc_datetime_usec))],
      postgres(data_layer),
      data_layer
    )
  end

  defp postgres(AshPostgres.DataLayer) do
    [
      quote do
        postgres do
          table "unused"
          repo AshMetrics.Test.Repo
        end
      end
    ]
  end

  defp postgres(_data_layer), do: []
end
