defmodule AshMetrics.Dsl.Tags do
  @moduledoc """
  The `tags` list of a counter or a distribution, and its normalized form.

  An entry is one of:

  * an atom, an open tag whose value a call site chooses freely
  * `{key, values}`, a closed tag whose value must be one of `values`
  * `{key, path: path}`, a tag the action changes read from the written record
    at `path`, optionally with `values:` closing it as the form above does

  Keyword syntax writes the entries carrying a list last; an explicit tuple
  may appear anywhere.

      tags: [:provider, :template, status: [:queued, :sent, :error]]
      tags: [{:status, [:queued, :sent, :error]}, :provider]
      tags: [state: [path: [:location, :state], values: [:tx, :ca]]]

  Every form normalizes to the `tags`, `tag_values` and `tag_paths` fields of
  the declaration, so nothing downstream sees the difference.

  ## Paths

  A path is a list of at least one field name. The first names an attribute,
  a calculation or an aggregate of the resource, and each further one an
  attribute of the embedded resource the previous one holds:
  `[:location, :shipping_address, :state]` names the `state` of the
  `shipping_address` of a record's `location`.

  The key is the tag's name. It need not be an attribute of the resource, and
  a call site passing the tag to `AshMetrics.increment/3` or
  `AshMetrics.observe/4` by hand passes the value itself, whatever the path
  says. A gauge's `group_by` takes no path.

  ## Reading a tag from the written record

  `AshMetrics.Changes.IncrementOnChange`,
  `AshMetrics.Changes.IncrementOnWrite` and
  `AshMetrics.Changes.ObserveElapsed` read every declared tag from the record
  their action wrote: one with a path at that path, and one without a path
  from the attribute, calculation or aggregate of the same name. A tag without
  a path that names none of these is left off, for the call site or the tag
  extractor to supply.

  The tag is left off the emission when a segment of the walk is `nil`, and
  when the value the walk arrives at is a map or a struct.

  An open tag read this way carries whatever the row holds, one timeseries
  per distinct value. Name a bounded field, or close the tag with
  `values:`; a free-text or user-entered attribute is neither.

  ## Calculations and aggregates

  When a metric's declared tags name calculations or aggregates of the
  resource, the change loads exactly those for the written record before
  reading its tags, once for every record it emits for, a bulk action
  included. A metric whose tags name none loads nothing. The record the action
  returns does not carry the loaded values.

  The load runs with `authorize?: false` and the changeset's domain and
  tenant, so a tag can carry a value the actor is not allowed to read. It
  passes no actor and none of the changeset's context, so a calculation
  reading `^actor(...)` or `^context(...)` sees `nil`. A calculation is loaded
  without arguments, so each argument takes its default.

  A `sum`, `max`, `min`, `first` or `avg` aggregate over no related rows is
  `nil` unless it declares `default:`, so its tag is left off; as a closed tag
  that is a failed emission, logged each time. A `count` is `0` and an
  `exists` is `false`.

  The loaded value is that of the data when the change emits: inside an open
  transaction it includes the transaction's uncommitted writes, and after the
  commit it may include writes committed since.

  A load that fails is logged, or rolls back the transaction open when it
  fails, as `AshMetrics.Changes.IncrementOnChange`, "Transactions",
  documents. `AshMetrics.Verifiers.VerifyChanges` rejects a tag read from a
  calculation or an aggregate by a change on a destroy action that is not
  soft.

  `AshMetrics.Verifiers.VerifyMetrics` checks every tag the changes read, with
  or without a path, against the resource while it compiles.
  """

  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution

  @typedoc "A `tags` entry: an open tag key, a closed one, or one with a path."
  @type declaration :: atom() | {atom(), [atom()]} | {atom(), keyword()}

  @typedoc "The declared values of the closed tags, by key."
  @type values :: %{optional(atom()) => [atom()]}

  @typedoc "The declared path of the tags read from the written record, by key."
  @type paths :: %{optional(atom()) => [atom(), ...]}

  @doc """
  Splits a declared `tags` list into every key, in declaration order, the
  declared values of the closed keys and the declared paths.

  A key declared twice appears twice in the keys and once in the values and
  the paths; a verifier rejects it.
  """
  @spec normalize([declaration()]) :: {[atom()], values(), paths()}
  def normalize(declarations) do
    {keys, values, paths} =
      Enum.reduce(declarations, {[], %{}, %{}}, fn declaration, {keys, values, paths} ->
        {key, declared_values, path} = parse(declaration)

        {[key | keys], put(values, key, declared_values), put(paths, key, path)}
      end)

    {Enum.reverse(keys), values, paths}
  end

  @doc false
  @spec transform(Counter.t() | Distribution.t()) ::
          {:ok, Counter.t() | Distribution.t()}
  def transform(metric) do
    {keys, values, paths} = normalize(metric.tags)

    {:ok, %{metric | tags: keys, tag_values: values, tag_paths: paths}}
  end

  @spec parse(declaration()) :: {atom(), [atom()] | nil, [atom()] | nil}
  defp parse({key, options}) do
    if path_form?(options) do
      {key, Keyword.get(options, :values), Keyword.get(options, :path)}
    else
      {key, options, nil}
    end
  end

  defp parse(key), do: {key, nil, nil}

  @spec path_form?([atom()] | keyword()) :: boolean()
  defp path_form?([{option, _value} | _rest]) when is_atom(option), do: true
  defp path_form?(_options), do: false

  @spec put(map(), atom(), term()) :: map()
  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
