defmodule AshMetrics.Test.PgJob do
  @moduledoc false
  # `AshMetrics.Test.Job` again, on Postgres instead of ETS, so that the
  # `:count` strategy can be asserted against a data layer that actually
  # compiles its queries to SQL.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status, :provider],
      period: 60_000,
      description: "Jobs waiting to be picked up"

    gauge :total, period: 30_000
  end

  postgres do
    table "pg_jobs"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :provider, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
