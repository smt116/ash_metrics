defmodule AshMetrics.Changes.IncrementOnWrite do
  @moduledoc """
  An `Ash.Resource.Change` that counts every successful write of an attribute.

  Declare it with `AshMetrics.increment_on_write/2` on the action that writes
  the attribute; that function states what it counts that
  `AshMetrics.increment_on_change/2` does not.

  The change registers an `Ash.Changeset.after_transaction/2` hook. On
  `{:ok, record}` it emits one count through `AshMetrics.increment/3` for the
  attribute's value on the record. On an error it emits nothing, and it never
  alters the action's result.

  The tags the emission carries, the closed-tag value it skips and the logging
  of an emission `AshMetrics.increment/3` rejects are those of
  `AshMetrics.Changes.IncrementOnChange`.

  ## Atomics

  The change runs atomically: the action can keep `require_atomic? true`, and
  `Ash.bulk_update/4` can use its `:atomic` strategy. A `where:` whose
  condition Ash cannot resolve before running the action, such as
  `Ash.Resource.Validation.Builtins.data_one_of/2` reading the original
  record, makes the action non-atomic again.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias AshMetrics.Changes.Emission

  @impl Ash.Resource.Change
  @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts), do: Emission.counter_options(opts, __MODULE__)

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
          {:ok, Changeset.t()}
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl Ash.Resource.Change
  @spec atomic?() :: true
  def atomic?, do: true

  @spec increment(Changeset.t(), keyword(), term()) :: :ok
  defp increment(changeset, opts, {:ok, record}) do
    Emission.emit(changeset, opts[:counter], fn -> Emission.count(changeset, opts, record) end)
  end

  defp increment(_changeset, _opts, _result), do: :ok
end
