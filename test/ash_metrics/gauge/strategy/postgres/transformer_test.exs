defmodule AshMetrics.Gauge.Strategy.Postgres.TransformerTest do
  # Captures the compiler's stderr, so it cannot run alongside other tests.
  # `ash_postgres` is always loaded here, so its absence is passed to
  # `transform/2` explicitly.
  use ExUnit.Case, async: false

  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy.Postgres.Transformer
  alias AshMetrics.Test.Compiler
  alias Spark.Error.DslError

  describe "with ash_postgres available" do
    test "compiles a gauge selecting Postgres.Count" do
      resource = resource(AshMetrics.Gauge.Strategy.Postgres.Count)

      assert %Gauge{strategy: AshMetrics.Gauge.Strategy.Postgres.Count} =
               AshMetrics.Info.metric!(resource, :backlog)

      assert {:ok, _dsl_state} = Transformer.transform(resource.spark_dsl_config())
    end
  end

  describe "without ash_postgres" do
    test "rejects a gauge selecting Postgres.Count" do
      resource = resource(AshMetrics.Gauge.Strategy.Postgres.Count)

      assert {:error, %DslError{module: ^resource, path: [:metrics, :gauge, :backlog]} = error} =
               Transformer.transform(resource.spark_dsl_config(), false)

      message = Exception.message(error)

      assert message =~
               "`AshMetrics.Gauge.Strategy.Postgres.Count` needs the `ash_postgres` " <>
                 "package, which is not available."

      assert message =~ ~s({:ash_postgres, "~> 2.13"})
      assert message =~ "such as `AshMetrics.Gauge.Strategy.Count`."
    end

    test "leaves a gauge with another strategy alone" do
      resource = resource(AshMetrics.Gauge.Strategy.Count)

      assert {:ok, _dsl_state} = Transformer.transform(resource.spark_dsl_config(), false)
    end
  end

  defp resource(strategy) do
    Compiler.compile_resource(
      quote do
        metrics do
          gauge :backlog, group_by: [:status], strategy: unquote(strategy)
        end
      end,
      [quote(do: attribute(:status, :atom))],
      [
        quote do
          postgres do
            table "unused"
            repo AshMetrics.Test.Repo
          end
        end
      ],
      AshPostgres.DataLayer
    )
  end
end
