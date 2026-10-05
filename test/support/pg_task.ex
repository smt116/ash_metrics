defmodule AshMetrics.Test.PgTask do
  @moduledoc false
  # A Postgres resource whose reads are narrowed three ways a gauge has to
  # honour: a base filter hiding archived rows, and a primary read action
  # whose preparation hides failed ones and sorts. Its gauges use the Postgres
  # strategies, and the integration tests compare each with its generic
  # counterpart on the same rows, also with filters through its
  # `AshMetrics.Test.PgTaskNote` rows.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics],
    primary_read_warning?: false

  require Ash.Query

  resource do
    base_filter expr(archived == false)
  end

  metrics do
    gauge :backlog,
      filter: expr(status != :done),
      group_by: [:status, :provider],
      strategy: AshMetrics.Gauge.Strategy.Postgres.Count

    gauge :total, strategy: AshMetrics.Gauge.Strategy.Postgres.Count

    gauge :backlog_age,
      filter: expr(status != :done),
      group_by: [:status, :provider],
      strategy: AshMetrics.Gauge.Strategy.Postgres.OldestAge

    gauge :queue_age,
      strategy: {AshMetrics.Gauge.Strategy.Postgres.OldestAge, attribute: :queued_at}
  end

  postgres do
    table "pg_tasks"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :provider, :string, public?: true
    attribute :archived, :boolean, public?: true, allow_nil?: false, default: false

    attribute :inserted_at, :utc_datetime_usec,
      public?: true,
      allow_nil?: false,
      default: &DateTime.utc_now/0

    attribute :queued_at, :naive_datetime, public?: true
  end

  relationships do
    has_many :notes, AshMetrics.Test.PgTaskNote, public?: true, destination_attribute: :task_id
  end

  aggregates do
    count :note_count, :notes
  end

  actions do
    defaults [:destroy, create: :*, update: :*]

    read :read do
      primary? true

      prepare fn query, _context ->
        query
        |> Ash.Query.filter(status != :failed)
        |> Ash.Query.sort(inserted_at: :desc)
      end
    end
  end
end
