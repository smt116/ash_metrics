defmodule AshMetrics.TagExtractor.Default do
  @moduledoc """
  The default `AshMetrics.TagExtractor`: the tenant, and nothing else.

  A tenant is taken only when it is a string, an atom or an integer. Anything
  else — a struct, a map, a list, a tuple — is dropped rather than stringified:
  a struct tenant is usually a loaded record, and inspecting it would put a
  primary key into a tag value, which is one timeseries per row.

  `nil` is dropped too, so an emission from outside a tenant context carries no
  tenant tag.

  An application with a compound tenant can reduce it to a bounded label in an
  extractor of its own.
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
