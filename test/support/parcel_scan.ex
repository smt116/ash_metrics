defmodule AshMetrics.Test.ParcelScan do
  @moduledoc false
  # The related rows the aggregates of `AshMetrics.Test.Parcel`, and of the
  # throwaway resources of `AshMetrics.Verifiers.VerifyMetricsTest`, read.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id

    attribute :station, :atom, public?: true
    attribute :payload, :map, public?: true
    attribute :readings, {:array, :integer}, public?: true
  end

  relationships do
    belongs_to :parcel, AshMetrics.Test.Parcel, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:parcel_id]]
  end
end
