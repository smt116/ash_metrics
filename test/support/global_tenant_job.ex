defmodule AshMetrics.Test.GlobalTenantJob do
  @moduledoc false
  # Attribute multitenancy with `global? true`, which lets a gauge read across
  # every tenant in one query grouped by the tenant attribute.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    gauge :backlog,
      filter: expr(status in [:pending, :processing]),
      group_by: [:status],
      description: "Jobs waiting to be picked up, across every tenant"
  end

  multitenancy do
    strategy :attribute
    attribute :org
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :org, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
