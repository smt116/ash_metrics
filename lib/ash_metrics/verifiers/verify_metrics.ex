defmodule AshMetrics.Verifiers.VerifyMetrics do
  @moduledoc """
  Checks the metric declarations of a resource while it compiles.

  The checks are:

  * metric names are unique — counters, gauges and distributions share one
    namespace, because they share one metric name
  * tag keys are not repeated
  * tag keys do not collide with the keys the configured
    `AshMetrics.TagExtractor` adds
  * a closed tag declares at least one value, and no value twice
  * bucket boundaries are a non-empty, strictly ascending list of positive
    numbers
  * a gauge groups by attributes of the resource, and by none of them twice

  A gauge's `group_by` is not checked against the reserved tags: a gauge has no
  call site, and its tags are exactly the values of its `group_by`.
  """

  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl Spark.Dsl.Verifier
  @spec verify(map()) :: :ok | {:error, Exception.t()}
  def verify(dsl_state) do
    metrics = Verifier.get_entities(dsl_state, [:metrics])

    with :ok <- verify_unique_names(dsl_state, metrics),
         do: verify_each(dsl_state, metrics)
  end

  defp verify_each(dsl_state, metrics) do
    Enum.find_value(metrics, :ok, fn metric ->
      case verify_metric(dsl_state, metric) do
        :ok -> nil
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp verify_unique_names(dsl_state, metrics) do
    case metrics |> Enum.map(& &1.name) |> duplicates() do
      [] ->
        :ok

      [name | _rest] ->
        error(
          dsl_state,
          Enum.find(metrics, &(&1.name == name)),
          "metric #{inspect(name)} is declared more than once. Counters, gauges " <>
            "and distributions share one namespace, because they share one metric name."
        )
    end
  end

  defp verify_metric(dsl_state, %Counter{} = counter), do: verify_tags(dsl_state, counter)

  defp verify_metric(dsl_state, %Distribution{} = distribution) do
    with :ok <- verify_tags(dsl_state, distribution),
         do: verify_buckets(dsl_state, distribution)
  end

  defp verify_metric(dsl_state, %Gauge{} = gauge) do
    with :ok <- verify_unique_group_by(dsl_state, gauge),
         do: verify_group_by_attributes(dsl_state, gauge)
  end

  defp verify_unique_group_by(dsl_state, %Gauge{} = gauge) do
    case duplicates(gauge.group_by) do
      [] ->
        :ok

      duplicated ->
        error(
          dsl_state,
          gauge,
          "gauge #{inspect(gauge.name)} groups by #{list(duplicated)} more than " <>
            "once. Each group_by attribute becomes one tag, so repeating it " <>
            "changes nothing."
        )
    end
  end

  defp verify_group_by_attributes(dsl_state, %Gauge{} = gauge) do
    case Enum.reject(gauge.group_by, &ResourceInfo.attribute(dsl_state, &1)) do
      [] ->
        :ok

      [name | _rest] ->
        error(
          dsl_state,
          gauge,
          "gauge #{inspect(gauge.name)} groups by #{inspect(name)}, which is not " <>
            "an attribute of this resource. A gauge groups by attributes, because " <>
            "it is a query over the resource's own table. Declared attributes: " <>
            attributes(dsl_state)
        )
    end
  end

  defp attributes(dsl_state) do
    dsl_state |> ResourceInfo.attributes() |> Enum.map(& &1.name) |> list()
  end

  defp verify_tags(dsl_state, metric) do
    with :ok <- verify_unique_tags(dsl_state, metric),
         :ok <- verify_reserved_tags(dsl_state, metric),
         do: verify_tag_values(dsl_state, metric)
  end

  defp verify_unique_tags(dsl_state, metric) do
    case duplicates(metric.tags) do
      [] ->
        :ok

      duplicated ->
        error(
          dsl_state,
          metric,
          "#{kind(metric)} #{inspect(metric.name)} declares the tag " <>
            "#{list(duplicated)} more than once."
        )
    end
  end

  defp verify_reserved_tags(dsl_state, metric) do
    extractor = Config.tag_extractor()

    case Enum.filter(metric.tags, &(&1 in extractor.tag_keys())) do
      [] ->
        :ok

      [tag | _rest] ->
        error(
          dsl_state,
          metric,
          "#{kind(metric)} #{inspect(metric.name)} declares the tag #{inspect(tag)}, " <>
            "which is reserved: it comes from the configured tag extractor " <>
            "#{inspect(extractor)}, which adds it to every emission."
        )
    end
  end

  defp verify_tag_values(dsl_state, metric) do
    Enum.reduce_while(metric.tags, :ok, fn tag, :ok ->
      case verify_values(dsl_state, metric, tag, Map.get(metric.tag_values, tag)) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_values(_dsl_state, _metric, _tag, nil), do: :ok

  defp verify_values(dsl_state, metric, tag, []) do
    error(
      dsl_state,
      metric,
      "#{kind(metric)} #{inspect(metric.name)} declares no values for the tag " <>
        "#{inspect(tag)}. A closed tag lists at least one value."
    )
  end

  defp verify_values(dsl_state, metric, tag, values) do
    case duplicates(values) do
      [] ->
        :ok

      duplicated ->
        error(
          dsl_state,
          metric,
          "#{kind(metric)} #{inspect(metric.name)} declares the value " <>
            "#{list(duplicated)} of the tag #{inspect(tag)} more than once."
        )
    end
  end

  defp verify_buckets(_dsl_state, %Distribution{buckets: nil}), do: :ok

  defp verify_buckets(dsl_state, %Distribution{buckets: buckets} = distribution) do
    if strictly_ascending_positive?(buckets) do
      :ok
    else
      error(
        dsl_state,
        distribution,
        "distribution #{inspect(distribution.name)} declares buckets " <>
          "#{inspect(buckets, charlists: :as_lists)}. Buckets must be a non-empty, " <>
          "strictly ascending list of positive numbers."
      )
    end
  end

  defp strictly_ascending_positive?([]), do: false

  defp strictly_ascending_positive?(buckets) do
    Enum.all?(buckets, &(&1 > 0)) and buckets == Enum.sort(buckets) and
      buckets == Enum.uniq(buckets)
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp list(values), do: Enum.map_join(values, ", ", &inspect/1)

  defp kind(%Counter{}), do: "counter"
  defp kind(%Distribution{}), do: "distribution"

  defp error(dsl_state, metric, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:metrics, metric.name],
       message: message,
       location: Entity.anno(metric)
     )}
  end
end
