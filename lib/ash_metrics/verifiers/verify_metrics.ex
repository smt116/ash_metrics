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
  * a tag's `path` starts at an attribute, a calculation or an aggregate of
    the resource, descends through embedded resources, never through a list,
    and ends at a field that is not an embedded resource, a map, a
    struct, a keyword list, a union or a tuple
  * a tag with no `path` does not name an attribute, a calculation or an
    aggregate whose type is a list, an embedded resource, a map, a struct, a
    keyword list, a union or a tuple, which the action changes could never
    read a single value from
  * a calculation a tag or the start of a path names takes no argument that
    is `allow_nil? false` and has no default
  * an aggregate a tag or the start of a path names is not a `list`
    aggregate; an aggregate whose type depends on a resource that is not
    compiled when the verifier runs is accepted unchecked
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

  # The types whose value wraps what it holds in an `%Ash.Union{}` or a tuple,
  # which a tag cannot carry and no path reaches inside.
  @wrapping_types [Ash.Type.Union, Ash.Type.Tuple]

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

  defp fields(dsl_state) do
    calculations = dsl_state |> ResourceInfo.calculations() |> Enum.map(& &1.name)
    aggregates = dsl_state |> ResourceInfo.aggregates() |> Enum.map(& &1.name)

    "Declared attributes: #{attributes(dsl_state)}; calculations: " <>
      "#{list(calculations)}; aggregates: #{list(aggregates)}"
  end

  # What a tag's key, or the first segment of its path, names on the resource.
  defp field(dsl_state, name) do
    cond do
      attribute = ResourceInfo.attribute(dsl_state, name) -> {:attribute, attribute}
      calculation = ResourceInfo.calculation(dsl_state, name) -> {:calculation, calculation}
      aggregate = ResourceInfo.aggregate(dsl_state, name) -> {:aggregate, aggregate}
      true -> nil
    end
  end

  defp verify_tags(dsl_state, metric) do
    with :ok <- verify_unique_tags(dsl_state, metric),
         :ok <- verify_reserved_tags(dsl_state, metric),
         :ok <- verify_tag_values(dsl_state, metric),
         :ok <- verify_tag_paths(dsl_state, metric),
         do: verify_pathless_tags(dsl_state, metric)
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
        "tag #{inspect(tag)}. A path names an attribute, calculation or " <>
        "aggregate of this resource, then an attribute of each embedded " <>
        "resource it descends into."
    )
  end

  defp verify_path(dsl_state, metric, tag, [first | rest]) do
    case field(dsl_state, first) do
      nil ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} starts at #{inspect(first)}, which is not an " <>
            "attribute, calculation or aggregate of this resource. " <>
            fields(dsl_state)
        )

      {:attribute, %{type: type}} ->
        verify_segment(dsl_state, metric, tag, first, type, rest)

      {kind, derived} ->
        verify_derived(dsl_state, metric, tag, kind, derived, fn type ->
          verify_segment(dsl_state, metric, tag, first, type, rest)
        end)
    end
  end

  # Checks a calculation or an aggregate, then passes its type to `verify`;
  # `:ok` without calling `verify` when the type cannot be determined.
  defp verify_derived(dsl_state, metric, tag, kind, derived, verify) do
    with :ok <- verify_derived(dsl_state, metric, tag, kind, derived) do
      case derived_type(dsl_state, kind, derived) do
        {:ok, type} -> verify.(type)
        :unknown -> :ok
      end
    end
  end

  # A calculation the action changes load must take no required argument, and
  # an aggregate must not be a list.
  defp verify_derived(dsl_state, metric, tag, :calculation, calculation) do
    case Enum.find(calculation.arguments, &required_argument?/1) do
      nil ->
        :ok

      argument ->
        error(
          dsl_state,
          metric,
          "#{kind(metric)} #{inspect(metric.name)} reads the tag #{inspect(tag)} " <>
            "from the calculation #{inspect(calculation.name)}, whose argument " <>
            "#{inspect(argument.name)} is required and has no default. The action " <>
            "changes load the calculation without arguments: give the argument a " <>
            "default or `allow_nil? true`."
        )
    end
  end

  defp verify_derived(dsl_state, metric, tag, :aggregate, %{kind: :list} = aggregate) do
    error(
      dsl_state,
      metric,
      "#{kind(metric)} #{inspect(metric.name)} reads the tag #{inspect(tag)} " <>
        "from the aggregate #{inspect(aggregate.name)}, which is a list " <>
        "aggregate. A tag carries one value."
    )
  end

  defp verify_derived(_dsl_state, _metric, _tag, :aggregate, _aggregate), do: :ok

  defp required_argument?(argument),
    do: argument.allow_nil? == false and is_nil(argument.default)

  # The type of a calculation or a non-list aggregate. `:unknown` for an
  # aggregate whose type depends on a related resource that is not compiled or
  # on a field that cannot be resolved.
  defp derived_type(_dsl_state, :calculation, calculation),
    do: {:ok, Ash.Type.get_type(calculation.type)}

  defp derived_type(_dsl_state, :aggregate, %{kind: :count}), do: {:ok, Ash.Type.Integer}
  defp derived_type(_dsl_state, :aggregate, %{kind: :exists}), do: {:ok, Ash.Type.Boolean}
  defp derived_type(_dsl_state, :aggregate, %{kind: :avg}), do: {:ok, Ash.Type.Float}

  defp derived_type(_dsl_state, :aggregate, %{kind: :custom, type: type}),
    do: {:ok, Ash.Type.get_type(type)}

  defp derived_type(dsl_state, :aggregate, aggregate) do
    with destination when is_atom(destination) and not is_nil(destination) <-
           destination(dsl_state, aggregate),
         true <- compiled?(destination),
         {:ok, type} when not is_nil(type) <- ResourceInfo.aggregate_type(dsl_state, aggregate) do
      {:ok, Ash.Type.get_type(type)}
    else
      _unknown -> :unknown
    end
  end

  # The resource an aggregate reads from, or `nil` when a resource on its
  # relationship path is not compiled.
  defp destination(_dsl_state, %{related?: false, resource: resource}), do: resource

  defp destination(dsl_state, %{relationship_path: [first | rest]}) do
    case ResourceInfo.relationship(dsl_state, first) do
      %{destination: destination} -> descend(destination, rest)
      nil -> nil
    end
  end

  defp destination(_dsl_state, _aggregate), do: nil

  defp descend(resource, []), do: resource

  defp descend(resource, [next | rest]) do
    with true <- compiled?(resource),
         %{destination: destination} <- ResourceInfo.relationship(resource, next) do
      descend(destination, rest)
    else
      _unknown -> nil
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

      type in @wrapping_types ->
        error(
          dsl_state,
          metric,
          "#{tagged(metric, tag)} ends at #{inspect(segment)}, whose type " <>
            "#{inspect(type)} wraps its value. A tag carries one value, and no " <>
            "path reaches inside that type."
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

  defp verify_pathless_tags(dsl_state, metric) do
    metric.tags
    |> Enum.reject(&Map.has_key?(metric.tag_paths, &1))
    |> Enum.reduce_while(:ok, fn tag, :ok ->
      case verify_pathless(dsl_state, metric, tag, field(dsl_state, tag)) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp verify_pathless(_dsl_state, _metric, _tag, nil), do: :ok

  defp verify_pathless(dsl_state, metric, tag, {:attribute, %{type: type}}),
    do: verify_single_value(dsl_state, metric, tag, :attribute, type)

  defp verify_pathless(dsl_state, metric, tag, {kind, derived}) do
    verify_derived(dsl_state, metric, tag, kind, derived, fn type ->
      verify_single_value(dsl_state, metric, tag, kind, type)
    end)
  end

  defp verify_single_value(dsl_state, metric, tag, kind, type) do
    case unwrap(type) do
      {:array, _item} ->
        error(
          dsl_state,
          metric,
          "#{kind(metric)} #{inspect(metric.name)} declares the tag " <>
            "#{inspect(tag)}, whose #{kind} has the type #{inspect(type)}, a " <>
            "list. A tag carries one value."
        )

      unwrapped ->
        if several_values?(unwrapped) do
          several_values(dsl_state, metric, tag, kind, type)
        else
          :ok
        end
    end
  end

  defp several_values(dsl_state, metric, tag, kind, type) do
    error(
      dsl_state,
      metric,
      "#{kind(metric)} #{inspect(metric.name)} declares the tag " <>
        "#{inspect(tag)}, whose #{kind} has the type #{inspect(type)}. " <>
        "A tag carries one value, so no emission could ever carry that " <>
        "#{kind}: " <> several_values_advice(tag, unwrap(type))
    )
  end

  defp several_values_advice(tag, type) do
    if ResourceInfo.resource?(type) do
      "declare `#{tag}: [path: [#{inspect(tag)}, ...]]` naming the attribute " <>
        "inside it that holds the value."
    else
      "no path reaches inside that type. Give the tag a key that names no " <>
        "field, for the call site to pass its value, or read it from a " <>
        "calculation that returns the single value."
    end
  end

  defp several_values?(type),
    do: type in @map_types or type in @wrapping_types or ResourceInfo.resource?(type)

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

  defp list([]), do: "none"
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
