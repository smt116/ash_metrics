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
  * a tag's `path` starts at an attribute of the resource, descends through
    embedded resources, never through a list, and ends at an attribute that
    is neither an embedded resource nor a map
  * a tag with no `path` does not name an attribute whose type is an embedded
    resource, a map, a struct or a keyword list, which the action changes
    could never read a value from
  * bucket boundaries are a non-empty, strictly ascending list of positive
    numbers
  * a distribution's name suffix is a non-empty atom holding no dot, so that
    it is one segment of the metric name
  * a gauge groups by attributes of the resource, and by none of them twice

  A gauge's `group_by` is not checked against the reserved tags: a gauge has no
  call site, and its tags are exactly the values of its `group_by`.
  """

  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type.NewType
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  # The types that hold several values under keys of their own, which a tag
  # can only carry one of, through a path.
  @map_types [Ash.Type.Map, Ash.Type.Struct, Ash.Type.Keyword]

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
         :ok <- verify_buckets(dsl_state, distribution),
         do: verify_suffix(dsl_state, distribution)
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
         :ok <- verify_tag_values(dsl_state, metric),
         :ok <- verify_tag_paths(dsl_state, metric),
         do: verify_map_typed_tags(dsl_state, metric)
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

  defp verify_tag_paths(dsl_state, metric) do
    Enum.reduce_while(metric.tag_paths, :ok, fn {tag, path}, :ok ->
      case verify_path(dsl_state, metric, tag, path) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_path(dsl_state, metric, tag, []) do
    error(
      dsl_state,
      metric,
      "#{kind(metric)} #{inspect(metric.name)} declares an empty path for the " <>
        "tag #{inspect(tag)}. A path names an attribute of this resource, then " <>
        "an attribute of each embedded resource it descends into."
    )
  end

  defp verify_path(dsl_state, metric, tag, [first | rest]) do
    case ResourceInfo.attribute(dsl_state, first) do
      nil ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} starts at #{inspect(first)}, which is not an " <>
            "attribute of this resource. Declared attributes: #{attributes(dsl_state)}"
        )

      %{type: type} ->
        verify_segment(dsl_state, metric, tag, first, type, rest)
    end
  end

  defp verify_segment(dsl_state, metric, tag, segment, type, rest) do
    case unwrap(type) do
      {:array, _item} ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} goes through #{inspect(segment)}, whose type " <>
            "#{inspect(type)} is a list. A path cannot go through a list: a tag " <>
            "carries one value."
        )

      unwrapped ->
        verify_unwrapped(dsl_state, metric, tag, segment, unwrapped, rest)
    end
  end

  defp verify_unwrapped(dsl_state, metric, tag, segment, type, []) do
    cond do
      ResourceInfo.resource?(type) ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} ends at #{inspect(segment)}, whose type " <>
            "#{inspect(type)} is an embedded resource. End the path at one of " <>
            "its attributes: #{attributes(type)}"
        )

      type in @map_types ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} ends at #{inspect(segment)}, whose type " <>
            "#{inspect(type)} holds several values. A tag carries one value."
        )

      true ->
        :ok
    end
  end

  defp verify_unwrapped(dsl_state, metric, tag, segment, type, [next | rest]) do
    cond do
      not ResourceInfo.resource?(type) ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} goes through #{inspect(segment)}, whose type " <>
            "#{inspect(type)} is not an embedded resource. A path descends " <>
            "through embedded attributes only."
        )

      is_nil(ResourceInfo.attribute(type, next)) ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} names #{inspect(next)}, which is not an " <>
            "attribute of #{inspect(type)}. Declared attributes: #{attributes(type)}"
        )

      true ->
        %{type: next_type} = ResourceInfo.attribute(type, next)

        verify_segment(dsl_state, metric, tag, next, next_type, rest)
    end
  end

  defp verify_map_typed_tags(dsl_state, metric) do
    metric.tags
    |> Enum.reject(&Map.has_key?(metric.tag_paths, &1))
    |> Enum.filter(&map_typed?(dsl_state, &1))
    |> case do
      [] ->
        :ok

      [tag | _rest] ->
        %{type: type} = ResourceInfo.attribute(dsl_state, tag)

        error(
          dsl_state,
          metric,
          "#{kind(metric)} #{inspect(metric.name)} declares the tag " <>
            "#{inspect(tag)}, whose attribute has the type #{inspect(type)}. " <>
            "A tag carries one value, so no emission could ever carry that " <>
            "attribute: declare `#{tag}: [path: [#{inspect(tag)}, ...]]` naming " <>
            "the attribute inside it that holds the value."
        )
    end
  end

  defp map_typed?(dsl_state, tag) do
    case ResourceInfo.attribute(dsl_state, tag) do
      nil -> false
      %{type: type} -> map_type?(unwrap(type))
    end
  end

  defp map_type?(type), do: type in @map_types or ResourceInfo.resource?(type)

  defp unwrap(type) when is_atom(type) do
    if compiled?(type) and NewType.new_type?(type) do
      NewType.subtype_of(type)
    else
      type
    end
  end

  defp unwrap(type), do: type

  defp compiled?(type), do: match?({:module, _module}, Code.ensure_compiled(type))

  defp tagged(metric, tag) do
    "the path of the tag #{inspect(tag)} of #{kind(metric)} #{inspect(metric.name)}"
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

  defp verify_suffix(dsl_state, %Distribution{suffix: suffix} = distribution) do
    segment = Atom.to_string(suffix)

    if segment != "" and not String.contains?(segment, ".") do
      :ok
    else
      error(
        dsl_state,
        distribution,
        "distribution #{inspect(distribution.name)} declares the suffix " <>
          "#{inspect(suffix)}. A suffix is the last segment of the metric " <>
          "name, so it is a non-empty atom holding no dot."
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
