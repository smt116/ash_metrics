defmodule AshMetrics.Gauge.Strategy.Postgres.Transformer do
  @moduledoc """
  Rejects a gauge whose strategy needs `ash_postgres`, an optional dependency
  of this package, when that package is not available.

  A resource declaring a gauge with `AshMetrics.Gauge.Strategy.Postgres.Count`
  as its strategy fails to compile, with an error naming the gauge, when
  `AshPostgres.DataLayer` is not loaded. It is a compile error, not a compiler
  warning.
  """

  use Spark.Dsl.Transformer

  alias AshMetrics.Dsl.Gauge
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  # Each strategy needing `ash_postgres`, with the generic strategy named as
  # its replacement.
  @alternatives %{
    AshMetrics.Gauge.Strategy.Postgres.Count => AshMetrics.Gauge.Strategy.Count
  }

  @impl Spark.Dsl.Transformer
  @spec transform(Spark.Dsl.t()) :: {:ok, Spark.Dsl.t()} | {:error, Exception.t()}
  def transform(dsl_state), do: transform(dsl_state, Code.ensure_loaded?(AshPostgres.DataLayer))

  # `available?` stands in for `Code.ensure_loaded?(AshPostgres.DataLayer)`,
  # which is always true in this package's own tests.
  @doc false
  @spec transform(Spark.Dsl.t(), boolean()) :: {:ok, Spark.Dsl.t()} | {:error, Exception.t()}
  def transform(dsl_state, true = _available?), do: {:ok, dsl_state}

  def transform(dsl_state, false = _available?) do
    dsl_state
    |> Transformer.get_entities([:metrics])
    |> Enum.find(&needs_postgres?/1)
    |> case do
      nil -> {:ok, dsl_state}
      gauge -> {:error, error(dsl_state, gauge)}
    end
  end

  @spec needs_postgres?(struct()) :: boolean()
  defp needs_postgres?(%Gauge{} = gauge),
    do: Map.has_key?(@alternatives, Gauge.strategy_module(gauge))

  defp needs_postgres?(_metric), do: false

  @spec error(Spark.Dsl.t(), Gauge.t()) :: Exception.t()
  defp error(dsl_state, %Gauge{} = gauge) do
    strategy = Gauge.strategy_module(gauge)

    DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: [:metrics, :gauge, gauge.name],
      location: Entity.anno(gauge),
      message: """
      `#{inspect(strategy)}` needs the `ash_postgres` package, which is not \
      available.

      Add it to your dependencies:

          {:ash_postgres, "~> 2.13"}

      or choose another strategy, such as \
      `#{inspect(Map.fetch!(@alternatives, strategy))}`.
      """
    )
  end
end
