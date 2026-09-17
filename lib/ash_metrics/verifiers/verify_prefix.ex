defmodule AshMetrics.Verifiers.VerifyPrefix do
  @moduledoc """
  Rejects a resource that declares metrics while `prefix` is unset.

  Every metric name this package produces starts with the configured prefix.
  See `AshMetrics.Config.prefix!/0` for where it must be set, and `AshMetrics`
  for how a verifier failure is reported.
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
