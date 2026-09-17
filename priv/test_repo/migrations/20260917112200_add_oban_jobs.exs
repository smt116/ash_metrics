defmodule AshMetrics.Test.Repo.Migrations.AddObanJobs do
  @moduledoc """
  Oban's own tables, needed by the integration test that drives the Oban
  poller through a real queue.

  Hand written rather than generated: `mix ash_postgres.generate_migrations`
  only knows about resources, and these tables belong to Oban.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
