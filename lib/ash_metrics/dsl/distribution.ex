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
  """

  defstruct [:name, :buckets, :description, unit: :unit, tags: [], __spark_metadata__: nil]

  @typedoc "A unit, or a `Telemetry.Metrics` unit conversion tuple."
  @type unit :: atom() | {atom(), atom()}

  @type t :: %__MODULE__{
          name: atom(),
          unit: unit(),
          buckets: [number()] | nil,
          tags: [atom()],
          description: String.t() | nil,
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }
end
