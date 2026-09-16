defmodule AshMetrics.MixProject do
  use Mix.Project

  @description "Declarative business metrics DSL for Ash resources, compiled to Telemetry.Metrics definitions."

  def project do
    [
      app: :ash_metrics,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.2"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      # Required by the Spark.Formatter plugin in .formatter.exs.
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
