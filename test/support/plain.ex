defmodule AshMetrics.Test.Plain do
  @moduledoc false
  # Deliberately does not use the AshMetrics extension, so resource discovery
  # and `AshMetrics.metrics/1` filtering can be tested.
  use Ash.Resource,
    domain: AshMetrics.Test.Mailings,
    data_layer: Ash.DataLayer.Simple

  attributes do
    uuid_primary_key :id
  end
end
