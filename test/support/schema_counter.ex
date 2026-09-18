defmodule AshMetrics.Test.SchemaCounter do
  @moduledoc false
  # `:context` multitenancy without a gauge: nothing is polled, so nothing has
  # to enumerate the tenants. Outside a domain, so resource discovery does not
  # find it.
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    counter :capture, tags: [status: [:succeeded, :failed]]
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
  end
end
