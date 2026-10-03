defmodule AshMetrics.Changes.Emission do
  @moduledoc false
  # What `AshMetrics.Changes.IncrementOnChange`,
  # `AshMetrics.Changes.IncrementOnWrite` and `AshMetrics.Changes.ObserveElapsed`
  # share: option validation for `init/1`, the metadata handed to the tag
  # extractor, the tags read from the resulting record, the count the two
  # increment changes emit, the hook that runs an emission once the action
  # succeeds, and the wrapper that turns a failed emission into a log line or,
  # for a failed load, into the error the hook handles.

  require Logger

  alias Ash.Changeset
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Changes.TagLoadError
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Info

  @doc false
  @spec counter_options(keyword(), module()) :: {:ok, keyword()} | {:error, String.t()}
  def counter_options(opts, change) do
    with {:ok, counter} <- option(opts, :counter, change),
         {:ok, attribute} <- option(opts, :attribute, change) do
      {:ok, counter: counter, attribute: attribute}
    end
  end

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
  @spec record_tags(Ash.Changeset.t(), Ash.Resource.record(), Counter.t() | Distribution.t()) ::
          AshMetrics.tags()
  def record_tags(changeset, record, metric) do
    resource = changeset.resource
    record = load_derived(changeset, record, metric)

    Enum.reduce(metric.tags, %{}, fn key, tags ->
      case tag(resource, record, path(metric, key)) do
        {:ok, value} -> Map.put(tags, key, value)
        :error -> tags
      end
    end)
  end

  @doc false
  @spec count(Ash.Changeset.t(), keyword(), Ash.Resource.record()) :: :ok
  def count(changeset, opts, record) do
    counter = Info.metric!(changeset.resource, opts[:counter])
    attribute = opts[:attribute]
    value = Map.get(record, attribute)

    if declared?(counter, attribute, value) do
      AshMetrics.increment(changeset.resource, counter.name,
        tags: counter_tags(changeset, record, counter, attribute, value),
        metadata: metadata(changeset)
      )
    end

    :ok
  end

  @doc """
  Registers a hook that calls `fun` with the changeset and the written record
  once the action succeeds. The hook is chosen when this runs, from whether a
  transaction is open; the timing each gives is documented in
  `AshMetrics.Changes.IncrementOnChange`, "Transactions". Either hook rolls
  back a transaction open when it runs with the error `fun` returns; with none
  open, the `after_transaction` hook logs it and leaves the action's result
  unchanged.
  """
  @spec on_success(
          Changeset.t(),
          (Changeset.t(), Ash.Resource.record() -> :ok | {:error, TagLoadError.t()})
        ) :: Changeset.t()
  def on_success(changeset, fun) do
    if Ash.DataLayer.in_transaction?(changeset.resource) do
      Changeset.after_action(changeset, fn changeset, record ->
        changeset |> fun.(record) |> roll_back(changeset, record)
      end)
    else
      Changeset.after_transaction(changeset, fn
        changeset, {:ok, record} = result ->
          changeset |> fun.(record) |> log(changeset)

          result

        _changeset, result ->
          result
      end)
    end
  end

  @doc false
  @spec emit(Ash.Changeset.t(), atom(), (-> :ok)) :: :ok | {:error, TagLoadError.t()}
  def emit(changeset, metric, fun) do
    fun.()

    :ok
  rescue
    error in TagLoadError -> {:error, error}
    error -> log_failure(changeset, metric, Exception.message(error))
  catch
    kind, reason -> log_failure(changeset, metric, Exception.format_banner(kind, reason))
  end

  @spec roll_back(:ok | {:error, TagLoadError.t()}, Changeset.t(), Ash.Resource.record()) ::
          {:ok, Ash.Resource.record()} | {:error, TagLoadError.t()}
  defp roll_back(:ok, _changeset, record), do: {:ok, record}

  defp roll_back({:error, error}, changeset, _record) do
    roll_back_open_transaction(changeset, error)

    {:error, error}
  end

  @spec log(:ok | {:error, TagLoadError.t()}, Changeset.t()) :: :ok
  defp log(:ok, _changeset), do: :ok

  defp log({:error, error}, changeset) do
    roll_back_open_transaction(changeset, error)

    log_failure(changeset, error.metric, Exception.message(error))
  end

  # A failed load may have left the open transaction unable to run another
  # statement.
  @spec roll_back_open_transaction(Changeset.t(), TagLoadError.t()) :: :ok
  defp roll_back_open_transaction(changeset, error) do
    if Ash.DataLayer.in_transaction?(changeset.resource) do
      Ash.DataLayer.rollback(changeset.resource, Ash.Error.to_error_class(error))
    end

    :ok
  end

  @spec log_failure(Ash.Changeset.t(), atom(), String.t()) :: :ok
  defp log_failure(changeset, metric, message) do
    Logger.error(
      "AshMetrics did not emit #{inspect(metric)} on " <>
        "#{inspect(changeset.resource)} from action " <>
        "#{inspect(changeset.action.name)}: #{message}"
    )
  end

  @spec declared?(Counter.t(), atom(), term()) :: boolean()
  defp declared?(counter, attribute, value) do
    case Map.fetch(counter.tag_values, attribute) do
      {:ok, values} -> value in values
      :error -> true
    end
  end

  @spec counter_tags(Ash.Changeset.t(), Ash.Resource.record(), Counter.t(), atom(), term()) ::
          AshMetrics.tags()
  defp counter_tags(changeset, record, counter, attribute, value) do
    changeset
    |> record_tags(record, counter)
    |> Map.put(attribute, value)
  end

  @spec path(Counter.t() | Distribution.t(), atom()) :: [atom()]
  defp path(metric, key), do: Map.get(metric.tag_paths, key, [key])

  # Loads the calculations and aggregates the metric's tags start at onto a
  # copy of the record; the record the action returns is never touched. A
  # load that raises, throws or exits raises `TagLoadError`. A three-element
  # throw carrying a query, changeset or action input with errors, or an Ash
  # error, is the data layer's rollback of an open transaction; its errors
  # become the `TagLoadError`'s `error`.
  @spec load_derived(Ash.Changeset.t(), Ash.Resource.record(), Counter.t() | Distribution.t()) ::
          Ash.Resource.record()
  defp load_derived(changeset, record, metric) do
    case derived_fields(changeset.resource, metric) do
      [] -> record
      fields -> load!(changeset, record, metric, fields)
    end
  end

  @spec load!(Ash.Changeset.t(), Ash.Resource.record(), Counter.t() | Distribution.t(), [atom()]) ::
          Ash.Resource.record()
  defp load!(changeset, record, metric, fields) do
    Ash.load!(record, fields,
      domain: changeset.domain,
      tenant: changeset.tenant,
      authorize?: false,
      reuse_values?: true
    )
  rescue
    error -> raise load_error(changeset, metric, fields, error)
  catch
    :throw, {_, _, payload} = reason ->
      raise load_error(changeset, metric, fields, rollback_error(payload) || {:throw, reason})

    kind, reason ->
      raise load_error(changeset, metric, fields, {kind, reason})
  end

  @spec rollback_error(term()) :: Exception.t() | nil
  defp rollback_error(%struct{errors: [_ | _] = errors})
       when struct in [Ash.Query, Ash.Changeset, Ash.ActionInput],
       do: Ash.Error.to_error_class(errors)

  defp rollback_error(payload) do
    if Ash.Error.ash_error?(payload), do: Ash.Error.to_error_class(payload)
  end

  @spec load_error(
          Ash.Changeset.t(),
          Counter.t() | Distribution.t(),
          [atom()],
          Exception.t() | {:throw | :exit, term()}
        ) :: TagLoadError.t()
  defp load_error(changeset, metric, fields, error) do
    TagLoadError.exception(
      resource: changeset.resource,
      action: changeset.action.name,
      metric: metric.name,
      fields: fields,
      error: error
    )
  end

  @spec derived_fields(module(), Counter.t() | Distribution.t()) :: [atom()]
  defp derived_fields(resource, metric) do
    metric.tags
    |> Enum.map(&(metric |> path(&1) |> List.first()))
    |> Enum.filter(&derived?(resource, &1))
    |> Enum.uniq()
  end

  @spec derived?(module(), atom() | nil) :: boolean()
  defp derived?(_resource, nil), do: false

  defp derived?(resource, name) do
    is_nil(ResourceInfo.attribute(resource, name)) and
      not is_nil(
        ResourceInfo.calculation(resource, name) || ResourceInfo.aggregate(resource, name)
      )
  end

  @spec tag(module(), Ash.Resource.record(), [atom()]) :: {:ok, term()} | :error
  defp tag(resource, record, [first | segments]) do
    cond do
      ResourceInfo.attribute(resource, first) || ResourceInfo.aggregate(resource, first) ->
        record |> Map.get(first) |> walk(segments)

      calculation = ResourceInfo.calculation(resource, first) ->
        record |> calculated(calculation) |> walk(segments)

      true ->
        :error
    end
  end

  defp tag(_resource, _record, []), do: :error

  @spec calculated(Ash.Resource.record(), Ash.Resource.Calculation.t()) :: term()
  defp calculated(record, %{field?: true, name: name}), do: Map.get(record, name)
  defp calculated(record, %{name: name}), do: Map.get(record.calculations, name)

  @spec walk(term(), [atom()]) :: {:ok, term()} | :error
  defp walk(nil, _segments), do: :error

  defp walk(value, [segment | segments]) when is_map(value),
    do: value |> Map.get(segment) |> walk(segments)

  defp walk(value, []) when not is_map(value), do: {:ok, value}
  defp walk(_value, _segments), do: :error

  @spec tenant(map(), term()) :: map()
  defp tenant(context, nil), do: context
  defp tenant(context, tenant), do: Map.put(context, :tenant, tenant)
end
