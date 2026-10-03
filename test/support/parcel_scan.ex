defmodule AshMetrics.Test.ParcelScan do
  @moduledoc false
  # The related rows the aggregates of `AshMetrics.Test.Parcel` count.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :parcel, AshMetrics.Test.Parcel, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:parcel_id]]
  end
end
