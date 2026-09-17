defmodule AshMetrics.Dsl.Tags do
  @moduledoc """
  The `tags` list of a counter or a distribution, and its normalized form.

  An entry is either an atom, an open tag whose value a call site chooses
  freely, or a `{key, values}` tuple, a closed tag whose value must be one of
  `values`. Keyword syntax writes the closed entries last; an explicit tuple
  may appear anywhere.

      tags: [:provider, :template, status: [:queued, :sent, :error]]
      tags: [{:status, [:queued, :sent, :error]}, :provider]

  Both forms normalize to the `tags` and `tag_values` fields of the
  declaration, so nothing downstream sees the difference.
  """

  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution

  @typedoc "A `tags` entry: an open tag key, or a closed one with its values."
  @type declaration :: atom() | {atom(), [atom()]}

  @typedoc "The declared values of the closed tags, by key."
  @type values :: %{optional(atom()) => [atom()]}

  @doc """
  Splits a declared `tags` list into every key, in declaration order, and the
  declared values of the closed keys.

  A key declared twice appears twice in the keys and once in the values; a
  verifier rejects it.
  """
  @spec normalize([declaration()]) :: {[atom()], values()}
  def normalize(declarations) do
    keys = Enum.map(declarations, &key/1)
    values = for {key, values} <- declarations, into: %{}, do: {key, values}

    {keys, values}
  end

  @doc false
  @spec transform(Counter.t() | Distribution.t()) ::
          {:ok, Counter.t() | Distribution.t()}
  def transform(metric) do
    {keys, values} = normalize(metric.tags)

    {:ok, %{metric | tags: keys, tag_values: values}}
  end

  @spec key(declaration()) :: atom()
  defp key({key, _values}), do: key
  defp key(key), do: key
end
