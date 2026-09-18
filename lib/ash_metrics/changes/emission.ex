defmodule AshMetrics.Changes.Emission do
  @moduledoc false
  # What `AshMetrics.Changes.IncrementOnChange` and
  # `AshMetrics.Changes.ObserveElapsed` share: option validation for `init/1`,
  # the metadata handed to the tag extractor, the tags read off the resulting
  # record, and the wrapper that turns a failed emission into a log line.

  require Logger

  alias Ash.Resource.Info, as: ResourceInfo

  @doc false
  @spec option(keyword(), atom(), module()) :: {:ok, atom()} | {:error, String.t()}
  def option(opts, key, change) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) ->
        {:ok, value}

      {:ok, value} ->
        {:error, "#{inspect(change)} takes an atom for `#{key}:`, got: #{inspect(value)}"}

      :error ->
        {:error, "#{inspect(change)} requires `#{key}:`"}
    end
  end

  @doc false
  @spec metadata(Ash.Changeset.t()) :: map()
  def metadata(changeset) do
    changeset.context
    |> tenant(changeset.tenant)
    |> Map.put(:resource, changeset.resource)
    |> Map.put(:action, changeset.action.name)
  end

  @doc false
  @spec attribute_tags(module(), Ash.Resource.record(), [atom()]) :: AshMetrics.tags()
  def attribute_tags(resource, record, keys) do
    keys
    |> Enum.filter(&ResourceInfo.attribute(resource, &1))
    |> Enum.reduce(%{}, fn key, tags ->
      case Map.get(record, key) do
        nil -> tags
        value -> Map.put(tags, key, value)
      end
    end)
  end

  @doc false
  @spec emit(Ash.Changeset.t(), atom(), (-> :ok)) :: :ok
  def emit(changeset, metric, fun) do
    fun.()

    :ok
  rescue
    error in ArgumentError ->
      Logger.error(
        "AshMetrics did not emit #{inspect(metric)} on " <>
          "#{inspect(changeset.resource)} from action " <>
          "#{inspect(changeset.action.name)}: #{Exception.message(error)}"
      )

      :ok
  end

  @spec tenant(map(), term()) :: map()
  defp tenant(context, nil), do: context
  defp tenant(context, tenant), do: Map.put(context, :tenant, tenant)
end
