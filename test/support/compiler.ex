defmodule AshMetrics.Test.Compiler do
  @moduledoc false
  # Compiles throwaway resources at test time so that the compile-time failures
  # of the verifiers can be asserted on.
  #
  # Spark runs verifiers from an `@after_verify` hook and deliberately converts
  # anything they raise into a compiler warning, so `assert_raise` cannot see
  # the error. `Spark.Test` exists for exactly this: it registers the calling
  # process as a collector and delivers the `Spark.Error.DslError` values as
  # data. Verification is therefore re-run in the test process, after the
  # module itself has been compiled with its output suppressed.
  #
  # Each resource gets a unique module name and is purged when the test that
  # built it finishes.

  require Spark.Test

  @spec dsl_errors(Macro.t(), [Macro.t()]) :: [Spark.Error.DslError.t()]
  def dsl_errors(metrics_block, attributes \\ []) do
    metrics_block |> compile_resource(attributes) |> dsl_errors_for()
  end

  # Re-verifies a module that is already compiled, which is how a verifier that
  # reads the application environment is tested: the configuration it read
  # while the module compiled can be changed and the verifier run again.
  @spec dsl_errors_for(module()) :: [Spark.Error.DslError.t()]
  def dsl_errors_for(module) do
    collected = Spark.Test.dsl_errors(do: module.__verify_spark_dsl__(module))

    Enum.flat_map(collected, fn {_module, errors} -> errors end)
  end

  # `attributes` are extra attribute declarations, quoted, for the resource's
  # `attributes` block. A gauge groups by attributes, so a verifier test needs
  # more than the primary key to have anything valid to group by.
  @spec compile_resource(Macro.t(), [Macro.t()]) :: module()
  def compile_resource(metrics_block, attributes \\ []) do
    module = unique_module()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_quoted(resource(module, metrics_block, attributes, [AshMetrics]), "nofile")
    end)

    module
  end

  # A transformer's error is a hard compile error rather than a warning, so
  # `dsl_errors/2` cannot collect it: nothing is left to verify once a
  # transformer has stopped. This compiles the resource and returns whatever it
  # raised instead.
  @spec transformer_error(Macro.t(), [module()], [Macro.t()]) :: Exception.t()
  def transformer_error(metrics_block, extensions \\ [AshMetrics], attributes \\ []) do
    module = unique_module()
    ast = resource(module, metrics_block, attributes, extensions)

    {result, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          Code.compile_quoted(ast, "nofile")
          :compiled
        rescue
          error -> error
        end
      end)

    case result do
      :compiled -> raise "expected #{inspect(module)} not to compile, but it did"
      error -> error
    end
  end

  @spec resource(module(), Macro.t(), [Macro.t()], [module()]) :: Macro.t()
  defp resource(module, metrics_block, attributes, extensions) do
    ExUnit.Callbacks.on_exit(fn -> purge(module) end)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Simple,
          extensions: unquote(extensions)

        unquote(metrics_block)

        attributes do
          uuid_primary_key :id

          unquote_splicing(attributes)
        end
      end
    end
  end

  @spec unique_module() :: module()
  defp unique_module do
    Module.concat([__MODULE__, "Resource#{System.unique_integer([:positive])}"])
  end

  @spec purge(module()) :: :ok
  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end
end
