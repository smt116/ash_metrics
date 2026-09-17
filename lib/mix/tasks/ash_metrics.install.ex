if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshMetrics.Install do
    @shortdoc "Installs AshMetrics. Should be run with `mix igniter.install ash_metrics`"

    @moduledoc """
    #{@shortdoc}

    Writes the two pieces of configuration that AshMetrics cannot default:

    * `prefix`, the first segment of every metric name, set to the name of
      the application being installed into. It is required rather than
      derived, because a compile-time lookup of the owning application is
      unreliable and a metric name is a permanent contract; see
      `AshMetrics.Config.prefix!/0`.
    * `otp_app`, the application whose Ash domains are searched for resources
      that declare metrics.

    Neither is overwritten if it is already configured, so the task is safe to
    run again. Everything else AshMetrics reads has a default, and the task
    prints those rather than writing them out, so that a configuration file
    only ever holds what the application actually decided.

        mix igniter.install ash_metrics
    """

    use Igniter.Mix.Task

    # Aliased under a prefix, because `Igniter.Project.Application` would
    # otherwise shadow Elixir's own `Application`.
    alias Igniter.Project.Application, as: ProjectApplication
    alias Igniter.Project.Config, as: ProjectConfig
    alias Igniter.Project.Formatter, as: ProjectFormatter

    @example "mix igniter.install ash_metrics"

    # Printed rather than written into `config/config.exs` as comments.
    # Igniter can emit a comment above a configuration block, through
    # `Igniter.Project.Config.configure_group/6`, but only when the
    # application is not configured at all, and Sourceror gives such a
    # comment line 0, which lands it above `import Config` in a
    # `config/config.exs` that holds nothing else. A notice is always shown
    # and never in the wrong place.
    @optional_keys """
    Everything else AshMetrics reads has a default. These are they:

        config :ash_metrics,
          outcome_tag: :outcome,
          name_builder: AshMetrics.NameBuilder.Default,
          tag_extractor: AshMetrics.TagExtractor.Default,
          backend: AshMetrics.Backend.Noop,
          poller: AshMetrics.Poller.GenServer,
          tenant_source: nil

    `poller` belongs in `config/config.exs` with the two keys that were
    written: it is read while resources compile. `tenant_source` is needed
    only by an application whose resources use Ash's `:context` multitenancy
    strategy and declare gauges.
    """

    @impl Igniter.Mix.Task
    def info(_argv, _source) do
      %Igniter.Mix.Task.Info{
        group: :ash_metrics,
        example: @example,
        schema: [],
        composes: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = ProjectApplication.app_name(igniter)

      igniter
      |> ProjectFormatter.import_dep(:ash_metrics)
      |> configure(app_name)
      |> Igniter.add_notice(@optional_keys)
    end

    # `configure_new/5` rather than `configure/6`, so that a `prefix` an
    # adopter has already chosen is never replaced by the application name.
    @spec configure(Igniter.t(), atom()) :: Igniter.t()
    defp configure(igniter, app_name) do
      igniter
      |> ProjectConfig.configure_new("config.exs", :ash_metrics, [:prefix], to_string(app_name))
      |> ProjectConfig.configure_new("config.exs", :ash_metrics, [:otp_app], app_name)
    end
  end
else
  defmodule Mix.Tasks.AshMetrics.Install do
    @shortdoc "Installs AshMetrics. Should be run with `mix igniter.install ash_metrics`"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_metrics.install' requires igniter to be run.

      Please add `{:igniter, "~> 0.6", only: [:dev, :test]}` to your
      dependencies, run `mix deps.get`, and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
