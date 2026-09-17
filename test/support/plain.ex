defmodule AshMetrics.Test.Plain do
  @moduledoc false
  # Does not use the AshMetrics extension, so resource discovery and
  # `AshMetrics.metrics_for/1` filtering can be tested.
  use Ash.Resource,
    domain: AshMetrics.Test.Mailings,
    data_layer: Ash.DataLayer.Simple

  attributes do
    uuid_primary_key :id
  end
end
