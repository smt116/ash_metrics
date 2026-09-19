defmodule AshMetrics.Test.Location do
  @moduledoc false
  # The embedded attribute of `AshMetrics.Test.Order`: a scalar a tag path
  # reads one segment in, and a further embedded resource it descends through.
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :state, :atom, public?: true, constraints: [one_of: [:tx, :ca, :ny]]
    attribute :shipping_address, AshMetrics.Test.Address, public?: true
  end
end
