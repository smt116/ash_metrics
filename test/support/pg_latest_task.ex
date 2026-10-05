defmodule AshMetrics.Test.PgLatestTask do
  @moduledoc false
  # A Postgres resource whose primary read action returns only the latest row
  # of each provider, so that a gauge over it reads a distinct query.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics],
    primary_read_warning?: false

  metrics do
    gauge :latest,
      group_by: [:status],
      strategy: AshMetrics.Gauge.Strategy.Postgres.Count

    gauge :total, strategy: AshMetrics.Gauge.Strategy.Postgres.Count
  end

  postgres do
    table "pg_latest_tasks"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :provider, :string, public?: true

    attribute :inserted_at, :utc_datetime_usec,
      public?: true,
      allow_nil?: false,
      default: &DateTime.utc_now/0
  end

  actions do
    defaults [:destroy, create: :*, update: :*]

    read :read do
      primary? true

      prepare build(distinct: [:provider], sort: [inserted_at: :desc])
    end
  end
end
