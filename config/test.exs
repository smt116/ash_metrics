import Config

config :ash_metrics,
  prefix: "test",
  otp_app: :ash_metrics,
  tenant_source: AshMetrics.Test.Tenants

config :ash_metrics,
  ash_domains: [AshMetrics.Test.Mailings, AshMetrics.Test.Queue, AshMetrics.Test.Pg]

# Required by Ash to compile the resources in `test/support`.
config :ash, default_string_length_count: :codepoints

# Ash logs every create at debug level, and the gauge tests seed a lot of rows.
config :logger, level: :warning

# The database behind the `:postgres` tagged integration tests, published by
# `docker-compose.yml`.
config :ash_metrics, ecto_repos: [AshMetrics.Test.Repo]

config :ash_metrics, AshMetrics.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("ASH_METRICS_PG_PORT", "54329")),
  database: "ash_metrics_test",
  # Deliberately not `Ecto.Adapters.SQL.Sandbox`. A gauge is polled from
  # whatever process the poller runs in — an Oban job, in the end — which a
  # sandbox connection checked out by the test process would not be allowed to
  # share. The integration tests empty their tables themselves instead.
  pool_size: 5,
  priv: "priv/test_repo",
  migrations_path: "priv/test_repo/migrations",
  snapshots_path: "priv/test_repo/snapshots"
