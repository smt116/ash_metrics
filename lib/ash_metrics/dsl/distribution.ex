defmodule AshMetrics.Dsl.Distribution do
  @moduledoc """
  A distribution declared in a resource's `metrics` block.

  A distribution answers "what is the spread?". It is observed manually with
  `AshMetrics.observe/4` and compiles to a `Telemetry.Metrics.Distribution`.

  `unit` is handed to `Telemetry.Metrics`, so it accepts either a plain unit
  atom or a conversion tuple such as `{:native, :millisecond}`, in which case
  the observed value is converted for you. `buckets` are histogram boundaries;
  they are reporter specific, so they are passed through as
  `reporter_options[:buckets]` rather than interpreted here.

  `suffix` is the last segment of the metric name; `default_suffix/1` derives
  it from `unit` when the declaration gives none.

  `tags` holds every declared tag key in declaration order, `tag_values` the
  declared values of the closed ones and `tag_paths` the declared path of
  those read from the written record; see `AshMetrics.Dsl.Tags`.
  """

  alias AshMetrics.Dsl.Tags

  defstruct [
    :name,
    :buckets,
    :description,
    :suffix,
    unit: :unit,
    tags: [],
    tag_values: %{},
    tag_paths: %{},
    __spark_metadata__: nil
  ]

  @typedoc "A unit, or a `Telemetry.Metrics` unit conversion tuple."
  @type unit :: atom() | {atom(), atom()}

  @type t :: %__MODULE__{
          name: atom(),
          unit: unit(),
          buckets: [number()] | nil,
          suffix: atom() | nil,
          tags: [atom()],
          tag_values: %{optional(atom()) => [atom()]},
          tag_paths: %{optional(atom()) => [atom(), ...]},
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }

  @time_units [:second, :millisecond, :microsecond, :nanosecond]
  @byte_units [:byte, :kilobyte, :megabyte]

  @doc """
  The units that measure a length of time.
  """
  @spec time_units() :: [atom()]
  def time_units, do: @time_units

  @doc """
  Whether `unit` is one of `time_units/0`.

  A conversion tuple is not one, whatever it converts between.
  """
  @spec time_unit?(unit()) :: boolean()
  def time_unit?(unit), do: unit in @time_units

  @doc """
  The last segment of the metric name of a distribution declaring `unit`, used
  when the declaration gives no `suffix`.

  It is `:duration` for a time unit or any conversion tuple, `:bytes` for
  `:byte`, `:kilobyte` or `:megabyte`, and `:value` for anything else,
  including the default unit `:unit`.
  """
  @spec default_suffix(unit()) :: atom()
  def default_suffix({_from, _to}), do: :duration

  def default_suffix(unit) do
    cond do
      time_unit?(unit) -> :duration
      unit in @byte_units -> :bytes
      true -> :value
    end
  end

  @doc false
  @spec transform(t()) :: {:ok, t()}
  def transform(%__MODULE__{} = distribution) do
    {keys, values, paths} = Tags.normalize(distribution.tags)

    {:ok,
     %{
       distribution
       | tags: keys,
         tag_values: values,
         tag_paths: paths,
         suffix: distribution.suffix || default_suffix(distribution.unit)
     }}
  end
end
