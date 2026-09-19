defmodule AshMetrics.Changes.ObserveElapsed do
  @moduledoc """
  An `Ash.Resource.Change` that records the time between two timestamps of the
  record an action wrote.

  Declare it with `AshMetrics.observe_elapsed/2` on the action that writes the
  later timestamp.

  The change registers an `Ash.Changeset.after_transaction/2` hook. On
  `{:ok, record}` it observes `to - from` through `AshMetrics.observe/4`, in
  the distribution's declared `unit`, which must be one of
  `AshMetrics.Dsl.Distribution.time_units/0`. `to` defaults to `:now`, the
  moment the hook runs. A negative result is observed as it is. On an error it
  observes nothing, and it never alters the action's result.

  Nothing is observed when either timestamp is `nil` on the record. Restrict
  the change to a particular transition with `where:` on the `change`
  declaration.

  The two timestamps may be `DateTime` or `NaiveDateTime` values; a
  `NaiveDateTime` compared with a `DateTime` is read as UTC.

  The observation carries every declared tag of the distribution that names an
  attribute of the resource and is not `nil` on the record, and whatever the
  configured `AshMetrics.TagExtractor` derives from the changeset's context,
  its tenant, the resource and the action name.

  An observation `AshMetrics.observe/4` rejects is logged at error level with
  the resource, the action and the distribution; the action still succeeds.

  ## Atomics

  The change runs atomically: the action can keep `require_atomic? true`, and
  `Ash.bulk_update/4` can use its `:atomic` strategy.

  A `where:` whose condition reads an attribute, such as `attribute_equals/2`
  or `data_one_of/2`, cannot be decided before the action runs and takes the
  action out of the atomic path. That action needs `require_atomic? false`,
  and `Ash.bulk_update/4` needs `strategy: :stream`; otherwise it fails with
  `Ash.Error.Framework.MustBeAtomic`. A condition over the action name or an
  argument leaves the action atomic.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias AshMetrics.Changes.Emission
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Info

  @impl Ash.Resource.Change
  @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts) do
    with {:ok, distribution} <- Emission.option(opts, :distribution, __MODULE__),
         {:ok, from} <- Emission.option(opts, :from, __MODULE__),
         {:ok, to} <- Emission.option(Keyword.put_new(opts, :to, :now), :to, __MODULE__) do
      {:ok, distribution: distribution, from: from, to: to}
    end
  end

  @impl Ash.Resource.Change
  @spec change(Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) :: Changeset.t()
  def change(changeset, opts, _context) do
    Changeset.after_transaction(changeset, fn changeset, result ->
      observe(changeset, opts, result)

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

  @spec observe(Changeset.t(), keyword(), term()) :: :ok
  defp observe(changeset, opts, {:ok, record}) do
    Emission.emit(changeset, opts[:distribution], fn ->
      distribution = Info.metric!(changeset.resource, opts[:distribution])
      from = Map.get(record, opts[:from])
      to = to(record, opts[:to])

      unless is_nil(from) or is_nil(to) do
        AshMetrics.observe(
          changeset.resource,
          distribution.name,
          elapsed(to, from, unit!(distribution)),
          tags: Emission.attribute_tags(changeset.resource, record, distribution.tags),
          metadata: Emission.metadata(changeset)
        )
      end

      :ok
    end)
  end

  defp observe(_changeset, _opts, _result), do: :ok

  @spec to(Ash.Resource.record(), atom()) :: DateTime.t() | NaiveDateTime.t() | nil
  defp to(_record, :now), do: DateTime.utc_now()
  defp to(record, attribute), do: Map.get(record, attribute)

  @spec unit!(Distribution.t()) :: atom()
  defp unit!(distribution) do
    if Distribution.time_unit?(distribution.unit) do
      distribution.unit
    else
      raise ArgumentError,
            "distribution #{inspect(distribution.name)} declares the unit " <>
              "#{inspect(distribution.unit)}, which is not a time unit. " <>
              "An elapsed time is measured in one of: " <>
              Enum.map_join(Distribution.time_units(), ", ", &inspect/1)
    end
  end

  @spec elapsed(
          DateTime.t() | NaiveDateTime.t(),
          DateTime.t() | NaiveDateTime.t(),
          atom()
        ) :: integer()
  defp elapsed(%DateTime{} = to, %DateTime{} = from, unit), do: DateTime.diff(to, from, unit)

  defp elapsed(%NaiveDateTime{} = to, %NaiveDateTime{} = from, unit),
    do: NaiveDateTime.diff(to, from, unit)

  defp elapsed(to, from, unit), do: DateTime.diff(utc(to), utc(from), unit)

  @spec utc(DateTime.t() | NaiveDateTime.t()) :: DateTime.t()
  defp utc(%DateTime{} = value), do: value
  defp utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
end
