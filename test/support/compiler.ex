defmodule AshMetrics.Test.Compiler do
  @moduledoc false
  # Compiles throwaway resources at test time so that the compile-time failures
  # of the verifiers can be asserted on.
  #
  # Spark runs verifiers from an `@after_verify` hook and converts anything
  # they raise into a compiler warning, so `assert_raise` cannot see the error.
  # The module is compiled with its output suppressed and its extensions'
  # verifiers are then run against its DSL config in the test process, which
  # returns the `Spark.Error.DslError` values as data.
  #
  # Each resource gets a unique module name and is purged when the test that
  # built it finishes.

  # `data_layer` replaces `Ash.DataLayer.Simple`, which supports no
  # aggregates.
  @spec dsl_errors(Macro.t(), [Macro.t()], [Macro.t()], module()) :: [Exception.t()]
  def dsl_errors(
        metrics_block,
        attributes \\ [],
        blocks \\ [],
        data_layer \\ Ash.DataLayer.Simple
      ) do
    metrics_block |> compile_resource(attributes, blocks, data_layer) |> dsl_errors_for()
  end

  # Runs the verifiers of a module that is already compiled, which is how a
  # verifier that reads the application environment is tested: the
  # configuration it read while the module compiled can be changed and the
  # verifiers run again.
  @spec dsl_errors_for(module()) :: [Exception.t()]
  def dsl_errors_for(module) do
    dsl_config = module.spark_dsl_config()

    module
    |> Spark.extensions()
    |> Enum.flat_map(& &1.verifiers())
    |> Enum.flat_map(fn verifier ->
      case verifier.verify(dsl_config) do
        {:error, error} -> List.wrap(error)
        _ok_or_warn -> []
      end
    end)
  end

  # `attributes` are extra attribute declarations, quoted, for the resource's
  # `attributes` block. A gauge groups by attributes, so a verifier test needs
  # more than the primary key to have anything valid to group by. `blocks` are
  # whole resource blocks, quoted, such as an `actions do` carrying a change.
  @spec compile_resource(Macro.t(), [Macro.t()], [Macro.t()], module()) :: module()
  def compile_resource(
        metrics_block,
        attributes \\ [],
        blocks \\ [],
        data_layer \\ Ash.DataLayer.Simple
      ) do
    module = unique_module()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_quoted(
        resource(module, metrics_block, attributes, [AshMetrics], blocks, data_layer),
        "nofile"
      )
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

  @spec resource(module(), Macro.t(), [Macro.t()], [module()], [Macro.t()], module()) ::
          Macro.t()
  defp resource(
         module,
         metrics_block,
         attributes,
         extensions,
         blocks \\ [],
         data_layer \\ Ash.DataLayer.Simple
       ) do
    ExUnit.Callbacks.on_exit(fn -> purge(module) end)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: unquote(data_layer),
          extensions: unquote(extensions)

        unquote(metrics_block)

        attributes do
          uuid_primary_key :id

          unquote_splicing(attributes)
        end

        unquote_splicing(blocks)
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
