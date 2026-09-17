defmodule AshMetrics.Test.Repo do
  @moduledoc false
  # The repo behind the `:postgres` tagged integration tests.
  #
  # Every other gauge resource in `test/support` runs on ETS, which answers
  # most questions but not the one that matters for the `:count` strategy:
  # whether distinct-then-count is a query a real SQL data layer will accept,
  # including for a group whose value is `nil`.
  #
  # It is started by `test/test_helper.exs`, and only when the `:postgres` tag
  # was included, so `mix test` never needs a database.
  use AshPostgres.Repo, otp_app: :ash_metrics

  @impl AshPostgres.Repo
  def installed_extensions, do: ["ash-functions"]

  @impl AshPostgres.Repo
  def min_pg_version, do: Version.parse!("17.0.0")
end
