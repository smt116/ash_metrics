defmodule AshMetrics.NameBuilder.Default do
  @moduledoc """
  The default `AshMetrics.NameBuilder`: four dot separated segments.

      <prefix>.<domain short name>.<resource name>.<metric>

  For example, a `counter :delivery` on `MyApp.Mailings.TemplatedDelivery` with
  `prefix: "myapp"` becomes `myapp.mailings.templated_delivery.delivery`.

  The domain segment comes from `Ash.Domain.Info.short_name/1`, which Ash
  derives from the last segment of the domain module name. The resource segment
  comes from `AshMetrics.Info.name/1`, so a resource whose module name does not
  read well in a metric name can override it with `name` in its `metrics`
  block.

  Consumers whose house style differs supply their own builder; see
  `AshMetrics.NameBuilder`.
  """

  @behaviour AshMetrics.NameBuilder

  alias Ash.Domain.Info, as: DomainInfo
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Info

  @impl AshMetrics.NameBuilder
  @spec build(String.t(), module(), atom()) :: String.t()
  def build(prefix, resource, metric) do
    domain = resource |> ResourceInfo.domain() |> DomainInfo.short_name()

    "#{prefix}.#{domain}.#{Info.name(resource)}.#{metric}"
  end
end
