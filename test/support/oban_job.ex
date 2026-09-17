defmodule AshMetrics.Test.ObanJob do
  @moduledoc false
  # A resource whose gauges are polled by Oban rather than by a timer. It is
  # backed by ETS, because everything the transformer generates — the action,
  # the schedule, the worker module — exists without a database; only actually
  # draining an Oban queue needs one, and that is what the `:postgres` tagged
  # integration tests are for.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban, AshMetrics]

  metrics do
    poller AshMetrics.Poller.AshOban

    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status],
      period: :timer.minutes(5),
      description: "Jobs waiting to be picked up, polled from Oban"
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
