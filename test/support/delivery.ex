defmodule AshMetrics.Test.Delivery do
  @moduledoc false
  use Ash.Resource,
    domain: AshMetrics.Test.Mailings,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshMetrics]

  metrics do
    name :templated_delivery

    counter :delivery,
      outcomes: [:queued, :sent, :bounced, :delivered, :error],
      tags: [:provider, :template],
      description: "Templated deliveries by outcome"

    distribution :send_latency,
      unit: {:native, :millisecond},
      buckets: [10, 50, 100, 250, 500],
      tags: [:provider],
      description: "Time from enqueue to provider acknowledgement"
  end

  attributes do
    uuid_primary_key :id
  end
end
