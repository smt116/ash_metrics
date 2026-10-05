defmodule AshMetrics.Test.AgedJob do
  @moduledoc false
  # The resource behind `AshMetrics.Gauge.Strategy.OldestAge`: a writable
  # `inserted_at`, so that a test can seed rows of a known age, and a naive
  # timestamp that may be nil, for the `attribute:` option.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog_age,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status, :provider],
      strategy: AshMetrics.Gauge.Strategy.OldestAge

    gauge :queue_age,
      filter: expr(status in [:pending, :processing]),
      strategy: {AshMetrics.Gauge.Strategy.OldestAge, attribute: :queued_at}
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

    attribute :queued_at, :naive_datetime, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
