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
      preferred_cli_env: ["test.integration": :test],
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
          AshMetrics.Supervisor,
          AshMetrics.Verifiers.VerifyMetrics,
          AshMetrics.Verifiers.VerifyPrefix,
          AshMetrics.Verifiers.VerifyTenantSource
        ],
        Behaviours: [
          AshMetrics.Backend,
          AshMetrics.Gauge.Strategy,
          AshMetrics.NameBuilder,
          AshMetrics.Poller,
          AshMetrics.TagExtractor,
          AshMetrics.TenantSource
        ],
        Defaults: [
          AshMetrics.Backend.Noop,
          AshMetrics.Gauge.Strategy.Count,
          AshMetrics.NameBuilder.Default,
          AshMetrics.Poller.AshOban,
          AshMetrics.Poller.AshOban.Cron,
          AshMetrics.Poller.AshOban.Emit,
          AshMetrics.Poller.AshOban.Memory,
          AshMetrics.Poller.AshOban.Transformer,
          AshMetrics.Poller.GenServer,
          AshMetrics.TagExtractor.Default
        ],
        Testing: [
          AshMetrics.Backend.Test,
          AshMetrics.Test
        ],
        "Mix tasks": [
          Mix.Tasks.AshMetrics.Install
        ]
      ],
      formatters: ["html"]
    ]
  end

  defp aliases do
    [
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshMetrics",
      docs: ["spark.cheat_sheets", "docs", "spark.replace_doc_links"],
      # `mix test` never touches a database. The tests that do are tagged
      # `:postgres`, excluded by default, and run by this alias against the
      # container in `docker-compose.yml`.
      "test.integration": [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "test --include postgres"
      ]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.2"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      # Needed only by `AshMetrics.Poller.AshOban`, which is not the default
      # poller. An application that polls from a timer never loads it.
      {:ash_oban, "~> 0.8", optional: true},
      # Only the Postgres integration suite needs a SQL data layer. It is
      # tagged `:postgres` and excluded from `mix test`; see `mix
      # test.integration`. `:dev` is in the list only because `.formatter.exs`
      # imports it, and `mix format` runs in `:dev`.
      {:ash_postgres, "~> 2.13", only: [:dev, :test]},
      # Required by the Spark.Formatter plugin in .formatter.exs and by
      # Igniter. Optional, and not restricted to an environment, because
      # Igniter depends on it unconditionally.
      {:sourceror, "~> 1.7", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      # Needed by `mix ash_metrics.install`, which a consumer runs through
      # `mix igniter.install ash_metrics`, and by the `spark.cheat_sheets`
      # task used to build the DSL reference. Optional, so that an
      # application which never runs the installer does not pull it in.
      {:igniter, "~> 0.6", optional: true}
    ]
  end
end
