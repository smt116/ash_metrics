defmodule AshMetrics.Test.PgTenantTask do
  @moduledoc false
  # `AshMetrics.Test.TenantJob` on Postgres: attribute multitenancy without
  # `global? true`, polled once per tenant.
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
    table "pg_tenant_tasks"
    repo AshMetrics.Test.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :org, :string, public?: true

    attribute :inserted_at, :utc_datetime_usec,
      public?: true,
      allow_nil?: false,
      default: &DateTime.utc_now/0
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
