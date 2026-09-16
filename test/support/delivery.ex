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
  end

  attributes do
    uuid_primary_key :id
  end
end
