defmodule AshMetrics.Test.Mailings do
  @moduledoc false
  # The module's last segment is the domain short name Ash derives, so metric
  # names built from this domain read `test.mailings.<resource>.<metric>`.
  use Ash.Domain

  resources do
    resource AshMetrics.Test.Delivery
    resource AshMetrics.Test.Invoice
    resource AshMetrics.Test.Shipment
    resource AshMetrics.Test.Plain
  end
end
