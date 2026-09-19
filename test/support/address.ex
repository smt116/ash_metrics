defmodule AshMetrics.Test.Address do
  @moduledoc false
  # The embedded attribute of `AshMetrics.Test.Location`, so that a tag path
  # has three segments to descend.
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :state, :atom, public?: true, constraints: [one_of: [:tx, :ca, :ny]]
  end
end
