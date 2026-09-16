defmodule AshMetrics.Verifiers.VerifyPrefix do
  @moduledoc """
  Rejects a resource that declares metrics while `prefix` is unset.

  Every metric name this package produces starts with the configured prefix. A
  missing prefix would otherwise surface weeks later as an empty dashboard
  rather than at build time, so it is checked while the resource compiles.

  Like every Spark verifier, a failure is reported by the compiler as a
  warning pointing at the resource, not as a hard error. Compile with
  `--warnings-as-errors` to turn it into one.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl Spark.Dsl.Verifier
  @spec verify(map()) :: :ok | {:error, Exception.t()}
  def verify(dsl_state) do
    case Application.get_env(:ash_metrics, :prefix) do
      prefix when is_binary(prefix) and prefix != "" ->
        :ok

      other ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:metrics],
           message: """
           `prefix` must be set to a non-empty string in the compile-time \
           configuration of :ash_metrics, got: #{inspect(other)}.

           Add this to `config/config.exs`:

               config :ash_metrics, prefix: "myapp"

           Every metric name declared here is prefixed with it, and a metric
           name is a permanent contract, so it is not derived from the
           application name.
           """
         )}
    end
  end
end
