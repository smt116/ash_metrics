defmodule AshMetrics.Test.Job do
  @moduledoc false
  # The single tenant gauge resource: one gauge with a filter and two group_by
  # attributes, and one that counts every row with no grouping at all.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status, :provider],
      period: 60_000,
      description: "Jobs waiting to be picked up"

    gauge :total, period: 30_000
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
