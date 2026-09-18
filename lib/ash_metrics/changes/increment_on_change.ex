defmodule AshMetrics.Changes.IncrementOnChange do
  @moduledoc """
  An `Ash.Resource.Change` that counts an attribute taking a new value.

  Declare it with `AshMetrics.increment_on_change/2` on the action that writes
  the attribute.

  The change registers an `Ash.Changeset.after_transaction/2` hook. On
  `{:ok, record}` it compares the attribute's value on the record with the
  changeset's original data and emits one count through `AshMetrics.increment/3`
  when the two differ; a create emits once for the value it wrote. On an error
  it emits nothing, and it never alters the action's result.

  The emission carries the attribute as a tag, every other declared tag of the
  counter that names an attribute of the resource and is not `nil` on the
  record, and whatever the configured `AshMetrics.TagExtractor` derives from
  the changeset's context, its tenant, the resource and the action name.

  Nothing is emitted when the counter declares the attribute as a closed tag
  and the new value is not one of the declared values.

  An emission `AshMetrics.increment/3` rejects is logged at error level with
  the resource, the action and the counter; the action still succeeds.

  ## Atomics

  The change reads the attribute's original value, which an atomic update does
  not load, so it declares itself non-atomic. The action must set
  `require_atomic? false`, and `Ash.bulk_update/4` must be given
  `strategy: :stream`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias AshMetrics.Changes.Emission
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Info

  @not_atomic "AshMetrics.Changes.IncrementOnChange compares an attribute " <>
                "with its original value, which an atomic update does not " <>
                "read. Set `require_atomic? false` on the action, or run a " <>
                "bulk update with `strategy: :stream`."

  @impl Ash.Resource.Change
  @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts) do
    with {:ok, counter} <- Emission.option(opts, :counter, __MODULE__),
         {:ok, attribute} <- Emission.option(opts, :attribute, __MODULE__) do
      {:ok, counter: counter, attribute: attribute}
    end
  end

  @impl Ash.Resource.Change
  @spec change(Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) :: Changeset.t()
  def change(changeset, opts, _context) do
    Changeset.after_transaction(changeset, fn changeset, result ->
      increment(changeset, opts, result)

      result
    end)
  end

  @impl Ash.Resource.Change
  @spec atomic(Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          {:not_atomic, String.t()}
  def atomic(_changeset, _opts, _context), do: {:not_atomic, @not_atomic}

  @impl Ash.Resource.Change
  @spec atomic?() :: false
  def atomic?, do: false

  @spec increment(Changeset.t(), keyword(), term()) :: :ok
  defp increment(changeset, opts, {:ok, record}) do
    Emission.emit(changeset, opts[:counter], fn ->
      counter = Info.metric!(changeset.resource, opts[:counter])
      attribute = opts[:attribute]
      value = Map.get(record, attribute)

      if changed?(changeset, attribute, value) and declared?(counter, attribute, value) do
        AshMetrics.increment(changeset.resource, counter.name,
          tags: tags(changeset.resource, record, counter, attribute, value),
          metadata: Emission.metadata(changeset)
        )
      end

      :ok
    end)
  end

  defp increment(_changeset, _opts, _result), do: :ok

  @spec changed?(Changeset.t(), atom(), term()) :: boolean()
  defp changed?(%Changeset{action_type: :create}, _attribute, _value), do: true

  defp changed?(changeset, attribute, value) do
    Changeset.get_data(changeset, attribute) != value
  end

  @spec declared?(Counter.t(), atom(), term()) :: boolean()
  defp declared?(counter, attribute, value) do
    case Map.fetch(counter.tag_values, attribute) do
      {:ok, values} -> value in values
      :error -> true
    end
  end

  @spec tags(module(), Ash.Resource.record(), Counter.t(), atom(), term()) :: AshMetrics.tags()
  defp tags(resource, record, counter, attribute, value) do
    resource
    |> Emission.attribute_tags(record, counter.tags)
    |> Map.put(attribute, value)
  end
end
