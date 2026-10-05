defmodule AshMetrics.Test.Repo do
  @moduledoc false
  # The repo behind the `:postgres` tagged integration tests, which assert
  # what ETS cannot: that the queries the gauge strategies build are ones a
  # real SQL data layer accepts, including for a group whose value is `nil`,
  # and that the Postgres strategies return what the generic ones do.
  #
  # It is started by `test/test_helper.exs`, and only when the `:postgres` tag
  # was included, so `mix test` never needs a database.
  use AshPostgres.Repo, otp_app: :ash_metrics

  @impl AshPostgres.Repo
  def installed_extensions, do: ["ash-functions"]

  @impl AshPostgres.Repo
  def min_pg_version, do: Version.parse!("17.0.0")

  # Where `AshPostgres.MultiTenancy.create_tenant!/2` finds the migrations of
  # the `:context` multitenant resources, run into each tenant's schema.
  @impl AshPostgres.Repo
  def tenant_migrations_path, do: "priv/test_repo/tenant_migrations"
end
