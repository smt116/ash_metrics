defmodule AshMetrics.TagExtractor do
  @moduledoc """
  Derives tags that every emission should carry from its metadata.

  Call sites pass `metadata:` — anything shaped like Ash event metadata, such
  as a changeset's context — and the extractor turns it into the tags that
  belong on every emission, such as the tenant.

  Configure one with:

      config :ash_metrics, tag_extractor: MyApp.TagExtractor

  The configured value must be a module; there is no function-capture or MFA
  form. The default is `AshMetrics.TagExtractor.Default`.

  An extractor must declare its keys in `c:tag_keys/0`; `extract/1` filters its
  output down to them. Those keys are published as the `tags:` of every
  compiled metric definition.
  """

  alias AshMetrics.Config

  @typedoc "Tags produced by an extractor."
  @type tags :: %{optional(atom()) => term()}

  @doc """
  The tag keys this extractor can produce.

  Read while the metric definitions are compiled, before any emission.
  """
  @callback tag_keys() :: [atom()]

  @doc """
  Returns the tags to add to an emission, given its metadata.

  Called on every emission: it should be cheap, and must not return a key whose
  value is unbounded.
  """
  @callback extract(metadata :: map()) :: tags()

  @doc """
  Extracts tags from `metadata` with the configured extractor, keeping only the
  keys the extractor declares.
  """
  @spec extract(map()) :: tags()
  def extract(metadata) do
    extractor = Config.tag_extractor()

    metadata
    |> extractor.extract()
    |> Map.take(extractor.tag_keys())
  end
end
