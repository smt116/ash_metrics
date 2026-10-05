defmodule AshMetrics.Test.PgPrefixedTask do
  @moduledoc false
  # A Postgres resource whose table lives in a schema of its own rather than
  # in `public`, without multitenancy.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog,
      filter: expr(status != :done),
      group_by: [:status],
      strategy: AshMetrics.Gauge.Strategy.Postgres.Count

    gauge :backlog_age,
      filter: expr(status != :done),
      group_by: [:status],
      strategy: AshMetrics.Gauge.Strategy.Postgres.OldestAge
  end

  postgres do
    table "pg_prefixed_tasks"
    schema "ash_metrics_prefixed"
    repo AshMetrics.Test.Repo
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
