defmodule AshMetrics.Test.Queue do
  @moduledoc false
  # Holds the ETS backed resources that gauges are polled against. They need a
  # real data layer, which the resources of `AshMetrics.Test.Mailings` do not.
  use Ash.Domain

  resources do
    resource AshMetrics.Test.Job
    resource AshMetrics.Test.TenantJob
    resource AshMetrics.Test.GlobalTenantJob
    resource AshMetrics.Test.SchemaJob
  end
end
