defmodule AshMetrics.Verifiers.VerifyMetrics do
  @moduledoc """
  Checks the metric declarations of a resource while it compiles.

  Everything here could in principle be discovered at runtime, on the first
  emission, in production. That is precisely why it is checked at compile time
  instead: a metric that is wrong is usually a metric nobody is looking at, so
  the mistake surfaces as a gap in a dashboard weeks later rather than as an
  error.

  The checks are:

  * metric names are unique — counters, gauges and distributions share one
    namespace, because they share one metric name
  * a counter declares at least one outcome, and no outcome twice
  * tag keys are not repeated
  * tag keys do not collide with the outcome tag or with the keys the
    configured `AshMetrics.TagExtractor` adds, since those are applied to every
    emission and would otherwise be overwritten
  * bucket boundaries are a non-empty, strictly ascending list of positive
    numbers
  * a gauge groups by attributes of the resource, and by none of them twice

  A gauge's `group_by` is deliberately not checked against the reserved tags. A
  reserved tag is one applied to every emission from a call site, and a gauge
  has no call site: its tags are exactly the values of its `group_by`.
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

  defp verify_metric(dsl_state, %Counter{} = counter) do
    with :ok <- verify_outcomes(dsl_state, counter), do: verify_tags(dsl_state, counter)
  end

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

  defp verify_outcomes(dsl_state, %Counter{outcomes: []} = counter) do
    error(
      dsl_state,
      counter,
      "counter #{inspect(counter.name)} declares no outcomes. The outcomes are " <>
        "the permitted values of the #{inspect(Config.outcome_tag())} tag, so at " <>
        "least one is required."
    )
  end

  defp verify_outcomes(dsl_state, %Counter{} = counter) do
    case duplicates(counter.outcomes) do
      [] ->
        :ok

      duplicated ->
        error(
          dsl_state,
          counter,
          "counter #{inspect(counter.name)} declares the outcome " <>
            "#{list(duplicated)} more than once."
        )
    end
  end

  defp verify_tags(dsl_state, metric) do
    with :ok <- verify_unique_tags(dsl_state, metric), do: verify_reserved_tags(dsl_state, metric)
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
    outcome_tag = Config.outcome_tag()
    extractor = Config.tag_extractor()
    reserved = [outcome_tag | extractor.tag_keys()]

    case Enum.filter(metric.tags, &(&1 in reserved)) do
      [] ->
        :ok

      [tag | _rest] ->
        error(dsl_state, metric, reserved_message(metric, tag, outcome_tag, extractor))
    end
  end

  defp reserved_message(metric, tag, outcome_tag, _extractor) when tag == outcome_tag do
    "#{kind(metric)} #{inspect(metric.name)} declares the tag #{inspect(tag)}, " <>
      "which is reserved: it is the outcome tag, set by " <>
      "`config :ash_metrics, outcome_tag: #{inspect(outcome_tag)}`, and is added " <>
      "to every counter emission."
  end

  defp reserved_message(metric, tag, _outcome_tag, extractor) do
    "#{kind(metric)} #{inspect(metric.name)} declares the tag #{inspect(tag)}, " <>
      "which is reserved: it comes from the configured tag extractor " <>
      "#{inspect(extractor)}, which adds it to every emission."
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
