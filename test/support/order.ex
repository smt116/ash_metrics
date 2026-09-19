defmodule AshMetrics.Test.Order do
  @moduledoc false
  # The resource the tag paths are exercised against: a `location` embedded
  # attribute holding the state one tag reads one segment in and the shipping
  # address whose state another reads two segments in, plus a closed path tag
  # and the timestamps the elapsed distribution measures between.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    counter :placements,
      tags: [
        state: [path: [:location, :state]],
        shipping_state: [path: [:location, :shipping_address, :state]],
        status: [:placed, :shipped]
      ],
      description: "Orders placed by state"

    counter :dispatches,
      tags: [
        status: [:placed, :shipped],
        state: [path: [:location, :state], values: [:tx, :ca]]
      ],
      description: "Orders dispatched from the states that ship"

    distribution :fulfillment_time,
      unit: :millisecond,
      tags: [state: [path: [:location, :state]]],
      description: "Time from placing an order to shipping it"
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom, public?: true, constraints: [one_of: [:placed, :shipped]]
    attribute :location, AshMetrics.Test.Location, public?: true

    create_timestamp :placed_at

    attribute :shipped_at, :utc_datetime_usec, public?: true, allow_nil?: true
  end
end
