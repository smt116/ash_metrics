defmodule AshMetrics.Test.Invoice do
  @moduledoc false
  use Ash.Resource,
    domain: AshMetrics.Test.Mailings,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshMetrics]

  metrics do
    counter :capture, outcomes: [:succeeded, :failed]
    distribution :settlement_lag
  end

  attributes do
    uuid_primary_key :id
  end
end
