defmodule AshMetrics.Test.PgSchemaTask do
  @moduledoc false
  # `AshMetrics.Test.SchemaJob` on Postgres: context multitenancy, one schema
  # per tenant of `AshMetrics.Test.Tenants`, polled once per tenant.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status],
      strategy: AshMetrics.Gauge.Strategy.Postgres.Count
  end

  postgres do
    table "pg_schema_tasks"
    repo AshMetrics.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :inserted_at, :utc_datetime_usec,
      public?: true,
      allow_nil?: false,
      default: &DateTime.utc_now/0
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
