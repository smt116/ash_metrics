defmodule AshMetrics.TagExtractor.Default do
  @moduledoc """
  The default `AshMetrics.TagExtractor`: the tenant, and nothing else.

  The tenant is the one dimension worth carrying on every metric that is not
  already in the metric name. Resource and action are, so they are not repeated
  here.

  A tenant is taken only when it is a string, an atom or an integer. Anything
  else — a struct, a map, a list, a tuple — is dropped rather than stringified.
  This is the anti-footgun, not a shortcut. A struct tenant is usually a loaded
  record, so inspecting it would put a primary key into a tag value, which
  means one timeseries per row: the backend bill grows without bound, the
  timeseries are useless for aggregation, and an identifier that was never
  meant to leave the database ends up in a metrics backend. A tenant this
  extractor cannot safely name is better untagged; an application that really
  does have a compound tenant knows how to reduce it to a bounded label and can
  say so in its own extractor.

  `nil` is dropped too, so an emission from outside a tenant context produces
  no tenant tag rather than a `nil` one.
  """

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  @spec tag_keys() :: [atom()]
  def tag_keys, do: [:tenant]

  @impl AshMetrics.TagExtractor
  @spec extract(map()) :: AshMetrics.TagExtractor.tags()
  def extract(metadata)

  def extract(%{tenant: nil}), do: %{}

  def extract(%{tenant: tenant})
      when is_binary(tenant) or is_atom(tenant) or is_integer(tenant),
      do: %{tenant: tenant}

  def extract(metadata) when is_map(metadata), do: %{}
end
