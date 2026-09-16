defmodule AshMetrics.MixProject do
  use Mix.Project

  @description "Declarative business metrics DSL for Ash resources, compiled to Telemetry.Metrics definitions."

  def project do
    [
      app: :ash_metrics,
      version: "0.1.0",
      description: @description,
      name: "AshMetrics",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/ash_metrics.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      # Hex requires the `links` key. Left empty until the repository
      # URL is decided; no placeholder URL is published.
      links: %{},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      formatters: ["html"]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.2"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      # Required by the Spark.Formatter plugin in .formatter.exs.
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
