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
      aliases: aliases(),
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/ash_metrics.plt"},
        # `:ex_unit` is needed by `AshMetrics.Test`, which ships in `lib` so
        # that consumers can use it, but only ever runs under ExUnit.
        plt_add_apps: [:ex_unit, :mix]
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
      files: ~w(lib documentation .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "documentation/dsls/DSL-AshMetrics.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        DSL: ~r"documentation/dsls"
      ],
      groups_for_modules: [
        "Extension & API": [
          AshMetrics,
          AshMetrics.Config,
          AshMetrics.Dsl,
          AshMetrics.Dsl.Counter,
          AshMetrics.Dsl.Distribution,
          AshMetrics.Dsl.Gauge,
          AshMetrics.Info,
          AshMetrics.Verifiers.VerifyMetrics,
          AshMetrics.Verifiers.VerifyPrefix
        ],
        Behaviours: [
          AshMetrics.Backend,
          AshMetrics.Gauge.Strategy,
          AshMetrics.NameBuilder,
          AshMetrics.TagExtractor
        ],
        Defaults: [
          AshMetrics.Backend.Noop,
          AshMetrics.Gauge.Strategy.Count,
          AshMetrics.NameBuilder.Default,
          AshMetrics.TagExtractor.Default
        ],
        Testing: [
          AshMetrics.Backend.Test,
          AshMetrics.Test
        ]
      ],
      formatters: ["html"]
    ]
  end

  defp aliases do
    [
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshMetrics",
      docs: ["spark.cheat_sheets", "docs", "spark.replace_doc_links"]
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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      # Required by the `spark.cheat_sheets` task used to build the DSL
      # reference. Not an installer; `mix igniter.install` is not supported.
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}
    ]
  end
end
