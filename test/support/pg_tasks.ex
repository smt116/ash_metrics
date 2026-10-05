defmodule AshMetrics.Test.PgTasks do
  @moduledoc false
  # Prepares the tables behind the Postgres strategy integration tests: the
  # tables of `AshMetrics.Test.PgTask` and its siblings, and one schema per
  # tenant of `AshMetrics.Test.Tenants` for `AshMetrics.Test.PgSchemaTask`.

  alias AshMetrics.Test.PgGlobalTenantTask
  alias AshMetrics.Test.PgLatestTask
  alias AshMetrics.Test.PgLimitedTask
  alias AshMetrics.Test.PgPrefixedTask
  alias AshMetrics.Test.PgSchemaTask
  alias AshMetrics.Test.PgTask
  alias AshMetrics.Test.PgTaskNote
  alias AshMetrics.Test.PgTenantTask
  alias AshMetrics.Test.Repo
  alias AshMetrics.Test.Tenants
  alias AshPostgres.DataLayer.Info, as: PostgresInfo

  # Notes first: they reference the rows of `PgTask`.
  @tables [PgTaskNote, PgTask, PgLatestTask, PgLimitedTask, PgTenantTask, PgGlobalTenantTask]

  # Drops each tenant's schema and creates it again with the tenant
  # migrations applied.
  @spec create_tenants!() :: :ok
  def create_tenants! do
    drop_tenants!()

    Enum.each(Tenants.list_tenants(), &AshPostgres.MultiTenancy.create_tenant!(&1, Repo))
  end

  @spec drop_tenants!() :: :ok
  def drop_tenants! do
    Enum.each(Tenants.list_tenants(), &Repo.query!(~s(DROP SCHEMA IF EXISTS "#{&1}" CASCADE)))
  end

  @spec clear!() :: :ok
  def clear! do
    Enum.each(@tables, &Repo.delete_all/1)
    Repo.delete_all(PgPrefixedTask, prefix: PostgresInfo.schema(PgPrefixedTask))
    Enum.each(Tenants.list_tenants(), &Repo.delete_all(PgSchemaTask, prefix: &1))
  end
end
