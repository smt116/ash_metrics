defmodule AshMetrics.Changes.IncrementOnChange do
  @moduledoc """
  An `Ash.Resource.Change` that counts an attribute taking a new value.

  Declare it with `AshMetrics.increment_on_change/2` on the action that writes
  the attribute.

  Once the action succeeds, the change compares the attribute's value on the
  record with the changeset's original data and emits one count through
  `AshMetrics.increment/3` when the two differ; a create emits once for the
  value it wrote. An action that fails emits nothing, and the change leaves
  the action's result alone, except as "Transactions" below describes.

  The change may sit on a create, an update or a destroy action. A destroy
  compares as an update does, so it emits only when it writes the attribute a
  new value, and its tags are read from the destroyed record; see
  `AshMetrics.Verifiers.VerifyChanges` for the tags a destroy cannot read.

  The emission carries the attribute as a tag, every other declared tag of the
  counter that is read from the record — by the name of an attribute,
  calculation or aggregate, or at the `path:` the tag declares, as
  `AshMetrics.Dsl.Tags` documents — and whatever the configured
  `AshMetrics.TagExtractor` derives from the changeset's context, its tenant,
  the resource and the action name.

  Nothing is emitted when the counter declares the attribute as a closed tag
  and the new value is not one of the declared values.

  An emission that raises, throws or exits, whether `AshMetrics.increment/3`
  rejects it, a calculation or aggregate a tag names fails to load or the tag
  extractor fails, is logged at error level with the resource, the action and
  the counter, and the action's result is left alone. A load that fails while
  a transaction is open is the exception "Transactions" describes.

  ## Transactions

  When the change emits depends on whether a transaction is open when the
  change runs, which is when the changeset is built, not when the action runs:

  * Built outside a transaction, the changeset carries an
    `Ash.Changeset.after_transaction/2` hook, and the emission happens after
    the action's transaction commits.
  * Built inside an open transaction, the changeset carries an
    `Ash.Changeset.after_action/2` hook, and the emission happens before the
    surrounding transaction commits. A later rollback, of the surrounding
    transaction or of the action because a later `after_action` hook failed,
    does not retract the emission.

  A changeset built outside a transaction and run inside one keeps the
  `after_transaction` hook, and Ash logs its warning about transaction hooks
  running inside a transaction.

  A calculation or aggregate a tag names that fails to load while a
  transaction is open, whether the data layer rejects it or it raises, throws
  or exits, rolls back that transaction instead of being logged, whichever
  hook the changeset carries. The call that opened the transaction returns
  `{:error, %Ash.Error.Unknown{}}` whose `errors` hold an
  `AshMetrics.Changes.TagLoadError`, and nothing written within the
  transaction persists. A bulk action run inside the
  transaction is rolled back the same way, whatever its strategy and its
  `rollback_on_error?`. With no transaction open, a load that fails is logged
  as above, and the write persists.

  A tag extractor that fails is logged whether or not a transaction is open;
  `c:AshMetrics.TagExtractor.extract/1` states what that means for an open
  transaction.

  ## Atomics

  The change reads the attribute's original value, which an atomic update does
  not load, so it declares itself non-atomic. The action must set
  `require_atomic? false`, and `Ash.bulk_update/4` must be given
  `strategy: :stream`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias AshMetrics.Changes.Emission
  alias AshMetrics.Changes.TagLoadError

  @not_atomic "AshMetrics.Changes.IncrementOnChange compares an attribute " <>
                "with its original value, which an atomic update does not " <>
                "read. Set `require_atomic? false` on the action, or run a " <>
                "bulk update with `strategy: :stream`."

  @impl Ash.Resource.Change
  @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts), do: Emission.counter_options(opts, __MODULE__)

  @impl Ash.Resource.Change
  @spec change(Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) :: Changeset.t()
  def change(changeset, opts, _context) do
    Emission.on_success(changeset, &increment(&1, opts, &2))
  end

  @impl Ash.Resource.Change
  @spec atomic(Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          {:not_atomic, String.t()}
  def atomic(_changeset, _opts, _context), do: {:not_atomic, @not_atomic}

  @impl Ash.Resource.Change
  @spec atomic?() :: false
  def atomic?, do: false

  @spec increment(Changeset.t(), keyword(), Ash.Resource.record()) ::
          :ok | {:error, TagLoadError.t()}
  defp increment(changeset, opts, record) do
    Emission.emit(changeset, opts[:counter], fn ->
      attribute = opts[:attribute]

      if changed?(changeset, attribute, Map.get(record, attribute)) do
        Emission.count(changeset, opts, record)
      else
        :ok
      end
    end)
  end

  @spec changed?(Changeset.t(), atom(), term()) :: boolean()
  defp changed?(%Changeset{action_type: :create}, _attribute, _value), do: true

  defp changed?(changeset, attribute, value) do
    Changeset.get_data(changeset, attribute) != value
  end
end
