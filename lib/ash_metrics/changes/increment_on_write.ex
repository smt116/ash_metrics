defmodule AshMetrics.Changes.IncrementOnWrite do
  @moduledoc """
  An `Ash.Resource.Change` that counts every successful write of an attribute.

  Declare it with `AshMetrics.increment_on_write/2` on the action that writes
  the attribute; that function states what it counts that
  `AshMetrics.increment_on_change/2` does not.

  Once the action succeeds, the change emits one count through
  `AshMetrics.increment/3` for the attribute's value on the record. An action
  that fails emits nothing.

  The actions it may sit on, the tags the emission carries, the closed-tag
  value it skips, the logging of an emission that fails, and when it emits
  within a transaction, including the one case in which a failing action still
  emits and the one in which a failed load rolls the transaction back, are
  those of `AshMetrics.Changes.IncrementOnChange`. A destroy counts the value
  the destroyed record holds.

  ## Atomics

  The change runs atomically: the action can keep `require_atomic? true`, and
  `Ash.bulk_update/4` can use its `:atomic` strategy. A `where:` whose
  condition reads an attribute takes the action out of the atomic path; see
  `AshMetrics.Changes.ObserveElapsed`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias AshMetrics.Changes.Emission
  alias AshMetrics.Changes.TagLoadError

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
          {:ok, Changeset.t()}
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl Ash.Resource.Change
  @spec atomic?() :: true
  def atomic?, do: true

  @spec increment(Changeset.t(), keyword(), Ash.Resource.record()) ::
          :ok | {:error, TagLoadError.t()}
  defp increment(changeset, opts, record) do
    Emission.emit(changeset, opts[:counter], fn -> Emission.count(changeset, opts, record) end)
  end
end
