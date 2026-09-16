defmodule AshMetrics.Test.SchemaCounter do
  @moduledoc false
  # `:context` multitenancy without a gauge: nothing is polled, so nothing has
  # to enumerate the tenants. Deliberately outside a domain, so that resource
  # discovery does not find it.
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMetrics]

  metrics do
    counter :capture, outcomes: [:succeeded, :failed]
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
  end
end
