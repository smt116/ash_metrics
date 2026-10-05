defmodule AshMetrics.Test.PgLimitedTask do
  @moduledoc false
  # A Postgres resource whose primary read action returns only its two oldest
  # rows, so that a gauge over it reads a limited query.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics],
    primary_read_warning?: false

  metrics do
    gauge :limited,
      group_by: [:status],
      strategy: AshMetrics.Gauge.Strategy.Postgres.Count

    gauge :limited_age,
      group_by: [:status],
      strategy: AshMetrics.Gauge.Strategy.Postgres.OldestAge
  end

  postgres do
    table "pg_limited_tasks"
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
    defaults [:destroy, create: :*, update: :*]

    read :read do
      primary? true

      prepare build(limit: 2, sort: [inserted_at: :asc])
    end
  end
end
