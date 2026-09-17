defmodule AshMetrics.Test.MarkedJob do
  @moduledoc false
  # The resource that overrides the configured poller, so that the application
  # under test has its gauges spread over two pollers rather than one.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    poller AshMetrics.Test.MarkerPoller

    gauge :backlog, filter: expr(status == :pending), group_by: [:status]
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
