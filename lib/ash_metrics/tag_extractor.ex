defmodule AshMetrics.TagExtractor do
  @moduledoc """
  Derives tags that every emission should carry from its metadata.

  Call sites pass `metadata:` — anything shaped like Ash event metadata, such
  as a changeset's context — and the extractor turns it into tags. This is how
  a tag that belongs on every metric, like the tenant, is applied without every
  call site remembering it.

  Configure one with:

      config :ash_metrics, tag_extractor: MyApp.TagExtractor

  Implementations are modules, so the configured value stays inspectable; there
  is no function-capture or MFA form. The default is
  `AshMetrics.TagExtractor.Default`.

  An extractor must declare its keys in `c:tag_keys/0`, and `extract/1` filters
  its output down to them. Those keys are what gets published as the `tags:` of
  every compiled metric definition, so a key returned but not declared would be
  silently dropped by the reporter anyway; filtering makes that a contract
  rather than a surprise. It also means a reserved key cannot be smuggled past
  the compile-time tag checks.
  """

  alias AshMetrics.Config

  @typedoc "Tags produced by an extractor."
  @type tags :: %{optional(atom()) => term()}

  @doc """
  The tag keys this extractor can produce.

  Declared rather than inferred, because the compiled metric definitions need
  the full key list before any emission has happened.
  """
  @callback tag_keys() :: [atom()]

  @doc """
  Returns the tags to add to an emission, given its metadata.

  Called on every emission, so it should be cheap, and it should return no key
  whose value is unbounded — see `AshMetrics.TagExtractor.Default` for why.
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
