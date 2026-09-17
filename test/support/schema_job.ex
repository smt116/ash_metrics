defmodule AshMetrics.Test.SchemaJob do
  @moduledoc false
  # Context multitenancy: the ETS data layer gives each tenant its own table,
  # named after the resource and the tenant. The tables must stay public, so
  # that the poller process can read what a test process seeded.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status],
      description: "Jobs waiting to be picked up, per tenant schema"
  end

  multitenancy do
    strategy :context
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
