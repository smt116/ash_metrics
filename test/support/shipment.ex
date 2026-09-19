defmodule AshMetrics.Test.Shipment do
  @moduledoc false
  # Declares its tags with closed value sets: the counter in keyword syntax,
  # the distribution with an explicit tuple ahead of an open tag. Its three
  # distributions cover the derived byte suffix and an explicitly declared one
  # alongside the derived duration.
  use Ash.Resource,
    domain: AshMetrics.Test.Mailings,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshMetrics]

  metrics do
    counter :dispatch,
      tags: [:carrier, status: [:queued, :shipped, :lost]],
      description: "Dispatches by status"

    distribution :transit_time,
      unit: {:native, :millisecond},
      tags: [{:carrier, [:ups, :dhl]}, :region]

    distribution :label_size, unit: :byte

    distribution :handling_delay,
      unit: {:native, :millisecond},
      suffix: :latency
  end

  attributes do
    uuid_primary_key :id
  end
end
