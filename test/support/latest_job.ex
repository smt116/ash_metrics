defmodule AshMetrics.Test.LatestJob do
  @moduledoc false
  # An ETS resource whose primary read action returns only the latest row of
  # each provider, so that a gauge over it reads a distinct query.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :processing, :done, :failed]]

    attribute :provider, :string, public?: true

    attribute :inserted_at, :utc_datetime_usec,
      public?: true,
      allow_nil?: false,
      default: &DateTime.utc_now/0
  end

  actions do
    defaults [:destroy, create: :*, update: :*]

    read :read do
      primary? true

      prepare build(distinct: [:provider], sort: [inserted_at: :desc])
    end
  end
end
