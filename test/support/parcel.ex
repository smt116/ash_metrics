defmodule AshMetrics.Test.Parcel do
  @moduledoc false
  # The resource the tags read from calculations and aggregates are exercised
  # against: an expression calculation, one taking an argument with a default,
  # one stored outside the struct, one that raises, one that throws an Ash
  # error as the data layer's rollback does, and aggregates over
  # `AshMetrics.Test.ParcelScan`.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    counter :receptions,
      tags: [
        :size,
        :weight_class,
        :hidden_size,
        :scan_count,
        :scanned,
        status: [:received, :delivered]
      ],
      description: "Parcels received and delivered"

    counter :audits,
      tags: [:faulty, status: [:received, :delivered]],
      description: "Parcels audited"

    counter :rollbacks,
      tags: [:rolled_back],
      description: "Parcels whose tag rolls back"

    distribution :transit_time,
      unit: :millisecond,
      tags: [:size, :scanned],
      description: "Time from receiving a parcel to delivering it"
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom, public?: true, constraints: [one_of: [:received, :delivered]]
    attribute :weight, :integer, public?: true
    attribute :destination, AshMetrics.Test.Location, public?: true

    create_timestamp :received_at

    attribute :delivered_at, :utc_datetime_usec, public?: true, allow_nil?: true
  end

  relationships do
    has_many :scans, AshMetrics.Test.ParcelScan, public?: true
  end

  calculations do
    calculate :size, :atom, expr(if weight > 10, do: :large, else: :small)

    calculate :weight_class,
              :atom,
              expr(if weight > ^arg(:threshold), do: :heavy, else: :light) do
      argument :threshold, :integer, default: 20
    end

    calculate :hidden_size, :atom, expr(if weight > 10, do: :large, else: :small), field?: false

    calculate :faulty, :atom, fn _records, _context -> raise "the calculation failed" end

    calculate :rolled_back, :atom, fn _records, _context ->
      throw({:rollback, make_ref(), Ash.Error.to_error_class("the data layer rolled back")})
    end
  end

  aggregates do
    count :scan_count, :scans
    exists :scanned, :scans
  end

  actions do
    defaults [:read, :destroy]

    create :receive do
      accept [:weight, :destination]

      change set_attribute(:status, :received)
      change AshMetrics.increment_on_change(:receptions, :status)
    end

    update :deliver do
      require_atomic? false
      accept [:status, :delivered_at, :weight]

      change AshMetrics.increment_on_write(:receptions, :status)

      change AshMetrics.observe_elapsed(:transit_time,
               from: :received_at,
               to: :delivered_at
             )
    end

    create :audit do
      accept [:weight]

      change set_attribute(:status, :received)
      change AshMetrics.increment_on_write(:audits, :status)
    end
  end
end
