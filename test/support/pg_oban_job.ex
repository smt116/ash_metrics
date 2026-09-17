defmodule AshMetrics.Test.PgObanJob do
  @moduledoc false
  # The one resource that has everything the Oban poller needs at once: a
  # Postgres data layer for Oban to store its jobs beside, the `AshOban`
  # extension, and a gauge that selects the Oban poller. It exists so that the
  # generated schedule can be driven through a real Oban queue rather than
  # only inspected.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban, AshMetrics]

  metrics do
    poller AshMetrics.Poller.AshOban

    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status],
      period: :timer.minutes(1),
      description: "Jobs waiting to be picked up, polled by Oban"
  end

  postgres do
    table "pg_oban_jobs"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
