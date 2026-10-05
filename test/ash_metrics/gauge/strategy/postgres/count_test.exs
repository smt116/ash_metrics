defmodule AshMetrics.Gauge.Strategy.Postgres.CountTest do
  # Captures the compiler's stderr, so it cannot run alongside other tests.
  # What the strategy computes is asserted against a database by
  # `AshMetrics.Integration.PostgresCountStrategyPostgresTest`.
  use ExUnit.Case, async: false

  alias AshMetrics.Test.Compiler
  alias Spark.Error.DslError

  describe "verify/2" do
    test "accepts a resource on AshPostgres.DataLayer" do
      assert errors(
               quote(do: gauge(:backlog, strategy: AshMetrics.Gauge.Strategy.Postgres.Count)),
               AshPostgres.DataLayer
             ) == []
    end

    test "rejects a resource on another data layer" do
      assert [%DslError{path: [:metrics, :backlog]} = error] =
               errors(
                 quote(do: gauge(:backlog, strategy: AshMetrics.Gauge.Strategy.Postgres.Count)),
                 Ash.DataLayer.Ets
               )

      assert Exception.message(error) =~
               "it queries through AshPostgres.DataLayer, and this resource uses " <>
                 "Ash.DataLayer.Ets"
    end

    test "rejects any option" do
      assert [%DslError{} = error] =
               errors(
                 quote do
                   gauge :backlog,
                     strategy: {AshMetrics.Gauge.Strategy.Postgres.Count, sample: 0.1}
                 end,
                 AshPostgres.DataLayer
               )

      assert Exception.message(error) =~ "it takes no options, and was given [sample: 0.1]."
    end
  end

  defp errors(declarations, data_layer) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end,
      [quote(do: attribute(:status, :atom))],
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
