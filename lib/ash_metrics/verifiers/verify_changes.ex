defmodule AshMetrics.Verifiers.VerifyChanges do
  @moduledoc """
  Checks the `AshMetrics` action changes a resource declares, wherever they
  are declared: in the resource's `changes` block or in an action's.

  For `AshMetrics.Changes.IncrementOnChange` the checks are:

  * the counter is declared on the resource, and is a counter rather than a
    gauge or a distribution
  * the attribute is an attribute of the resource
  * the counter declares the attribute as a tag
  * every other closed tag of the counter names an attribute of the resource,
    since the change has nowhere else to read a required tag from

  See `AshMetrics` for how a verifier failure is reported.
  """

  use Spark.Dsl.Verifier

  alias Ash.Resource.Change
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Changes.IncrementOnChange
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Info
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @typedoc "An action name, or `nil` for a change declared on the resource."
  @type source :: atom() | nil

  @impl Spark.Dsl.Verifier
  @spec verify(map()) :: :ok | {:error, Exception.t()}
  def verify(dsl_state) do
    dsl_state
    |> changes()
    |> Enum.reduce_while(:ok, fn {source, change}, :ok ->
      case verify_change(dsl_state, source, change) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec changes(map()) :: [{source(), Change.t()}]
  defp changes(dsl_state) do
    resource_changes = Enum.map(ResourceInfo.changes(dsl_state), &{nil, &1})

    action_changes =
      Enum.flat_map(ResourceInfo.actions(dsl_state), fn action ->
        action |> Map.get(:changes, []) |> Enum.map(&{action.name, &1})
      end)

    Enum.filter(resource_changes ++ action_changes, &match?({_source, %Change{}}, &1))
  end

  @spec verify_change(map(), source(), Change.t()) :: :ok | {:error, Exception.t()}
  defp verify_change(dsl_state, source, %Change{change: {IncrementOnChange, opts}} = change) do
    with {:ok, counter} <- counter(dsl_state, source, change, opts[:counter]),
         :ok <- verify_attribute(dsl_state, source, change, counter, opts[:attribute]),
         do: verify_closed_tags(dsl_state, source, change, counter)
  end

  defp verify_change(_dsl_state, _source, _change), do: :ok

  @spec counter(map(), source(), Change.t(), atom()) ::
          {:ok, Counter.t()} | {:error, Exception.t()}
  defp counter(dsl_state, source, change, name) do
    case Info.metric(dsl_state, name) do
      {:ok, %Counter{} = counter} ->
        {:ok, counter}

      {:ok, other} ->
        error(
          dsl_state,
          source,
          change,
          "#{where(source)} increments #{inspect(name)}, which is a " <>
            "#{kind(other)} rather than a counter. Declare a counter, or " <>
            "point the change at one."
        )

      :error ->
        error(
          dsl_state,
          source,
          change,
          "#{where(source)} increments #{inspect(name)}, which this resource " <>
            "does not declare. Declare `counter #{inspect(name)}` in the " <>
            "metrics block. Declared metrics: #{metrics(dsl_state)}"
        )
    end
  end

  @spec verify_attribute(map(), source(), Change.t(), Counter.t(), atom()) ::
          :ok | {:error, Exception.t()}
  defp verify_attribute(dsl_state, source, change, counter, attribute) do
    cond do
      is_nil(ResourceInfo.attribute(dsl_state, attribute)) ->
        error(
          dsl_state,
          source,
          change,
          "#{where(source)} counts changes of #{inspect(attribute)}, which is " <>
            "not an attribute of this resource. Declared attributes: " <>
            attributes(dsl_state)
        )

      attribute not in counter.tags ->
        error(
          dsl_state,
          source,
          change,
          "#{where(source)} counts changes of #{inspect(attribute)} into the " <>
            "counter #{inspect(counter.name)}, which does not declare " <>
            "#{inspect(attribute)} as a tag. Add it to that counter's `tags`. " <>
            "Declared tags: #{list(counter.tags)}"
        )

      true ->
        :ok
    end
  end

  @spec verify_closed_tags(map(), source(), Change.t(), Counter.t()) ::
          :ok | {:error, Exception.t()}
  defp verify_closed_tags(dsl_state, source, change, counter) do
    counter.tag_values
    |> Map.keys()
    |> Enum.reject(&ResourceInfo.attribute(dsl_state, &1))
    |> case do
      [] ->
        :ok

      [tag | _rest] ->
        error(
          dsl_state,
          source,
          change,
          "#{where(source)} increments #{inspect(counter.name)}, whose closed " <>
            "tag #{inspect(tag)} is not an attribute of this resource. The " <>
            "change reads every tag but the counted one off the record, so no " <>
            "emission could ever carry it. Make it an attribute, open the tag, " <>
            "or emit that counter by hand."
        )
    end
  end

  @spec where(source()) :: String.t()
  defp where(nil), do: "the resource-level change"
  defp where(action), do: "action #{inspect(action)}"

  @spec kind(Info.metric()) :: String.t()
  defp kind(%Distribution{}), do: "distribution"
  defp kind(%Gauge{}), do: "gauge"

  @spec metrics(map()) :: String.t()
  defp metrics(dsl_state) do
    dsl_state |> Info.metrics() |> Enum.map(& &1.name) |> list()
  end

  @spec attributes(map()) :: String.t()
  defp attributes(dsl_state) do
    dsl_state |> ResourceInfo.attributes() |> Enum.map(& &1.name) |> list()
  end

  @spec list([atom()]) :: String.t()
  defp list([]), do: "none"
  defp list(values), do: Enum.map_join(values, ", ", &inspect/1)

  @spec error(map(), source(), Change.t(), String.t()) :: {:error, Exception.t()}
  defp error(dsl_state, source, change, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: path(source),
       message: message,
       location: Entity.anno(change)
     )}
  end

  @spec path(source()) :: [atom()]
  defp path(nil), do: [:changes]
  defp path(action), do: [:actions, action]
end
