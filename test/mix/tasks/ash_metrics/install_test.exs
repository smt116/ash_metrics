defmodule Mix.Tasks.AshMetrics.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # `Igniter.Test.test_project/1` names the generated application `:test`, so
  # that is the prefix and the `otp_app` the installer should derive, and
  # `Test.*` is the namespace of everything below.

  # The `mix.exs` of `test_project/1` names no application module, which would
  # send `Igniter.Project.Application.add_new_child/3` down its "create the
  # application" path. A generated Phoenix or Mix application names one.
  @mix_exs """
  defmodule Test.MixProject do
    use Mix.Project

    def project do
      [
        app: :test,
        version: "0.1.0",
        elixir: "~> 1.17",
        start_permanent: Mix.env() == :prod,
        deps: deps()
      ]
    end

    def application do
      [
        mod: {Test.Application, []},
        extra_applications: [:logger]
      ]
    end

    defp deps do
      []
    end
  end
  """

  @application """
  defmodule Test.Application do
    @moduledoc false

    use Application

    @impl true
    def start(_type, _args) do
      children = [
        TestWeb.Telemetry,
        Test.Repo,
        TestWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: Test.Supervisor)
    end
  end
  """

  @repo """
  defmodule Test.Repo do
    use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
  end
  """

  @telemetry """
  defmodule TestWeb.Telemetry do
    use Supervisor
    import Telemetry.Metrics

    def start_link(arg) do
      Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
    end

    @impl true
    def init(_arg) do
      children = [
        {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    def metrics do
      [
        summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
        counter("test.repo.query.count")
      ]
    end
  end
  """

  defp phoenix_shaped_project(overrides \\ %{}) do
    test_project(
      files:
        Map.merge(
          %{
            "mix.exs" => @mix_exs,
            "lib/test/application.ex" => @application,
            "lib/test/repo.ex" => @repo,
            "lib/test_web/telemetry.ex" => @telemetry,
            "config/config.exs" => "import Config\n"
          },
          overrides
        )
    )
  end

  defp install(igniter), do: Igniter.compose_task(igniter, "ash_metrics.install", [])

  defp contents(igniter, path) do
    Rewrite.Source.get(igniter.rewrite.sources[path], :content)
  end

  describe "configuration" do
    test "writes the prefix and the otp_app of the application" do
      phoenix_shaped_project()
      |> install()
      |> assert_has_patch("config/config.exs", """
      + |config :ash_metrics, prefix: "test", otp_app: :test
      """)
    end

    test "adds the keys an application already configured is missing" do
      %{"config/config.exs" => "import Config\n\nconfig :ash_metrics, prefix: \"custom\"\n"}
      |> phoenix_shaped_project()
      |> install()
      |> assert_has_patch("config/config.exs", """
      + |config :ash_metrics, prefix: "custom", otp_app: :test
      """)
    end

    test "leaves a prefix the application has already chosen alone" do
      %{
        "config/config.exs" =>
          "import Config\n\nconfig :ash_metrics, prefix: \"chosen\", otp_app: :chosen\n"
      }
      |> phoenix_shaped_project()
      |> install()
      |> assert_unchanged("config/config.exs")
    end

    test "imports the formatter configuration of the package" do
      phoenix_shaped_project()
      |> install()
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:ash_metrics]
      """)
    end

    test "prints the optional keys with their defaults" do
      igniter = install(phoenix_shaped_project())

      assert_has_notice(igniter, &String.contains?(&1, "backend: AshMetrics.Backend.Noop"))
      assert_has_notice(igniter, &String.contains?(&1, "poller: AshMetrics.Poller.GenServer"))
      assert_has_notice(igniter, &String.contains?(&1, "tenant_source: nil"))
    end
  end

  describe "the telemetry module" do
    test "gets the metrics appended to what it reports" do
      phoenix_shaped_project()
      |> install()
      |> assert_has_patch("lib/test_web/telemetry.ex", """
      + |    ] ++ AshMetrics.metrics()
      """)
    end

    test "is left alone when it already reports them" do
      appended =
        String.replace(
          @telemetry,
          "      counter(\"test.repo.query.count\")\n    ]\n",
          "      counter(\"test.repo.query.count\")\n    ] ++ AshMetrics.metrics()\n"
        )

      %{"lib/test_web/telemetry.ex" => appended}
      |> phoenix_shaped_project()
      |> install()
      |> assert_unchanged("lib/test_web/telemetry.ex")
    end

    test "is not looked for in a module that defines metrics/0 without importing" do
      without_import = String.replace(@telemetry, "  import Telemetry.Metrics\n", "")

      %{"lib/test_web/telemetry.ex" => without_import}
      |> phoenix_shaped_project()
      |> install()
      |> assert_unchanged("lib/test_web/telemetry.ex")
    end

    test "is replaced by a notice when the application has none" do
      igniter =
        %{"lib/test_web/telemetry.ex" => "defmodule TestWeb.Telemetry do\nend\n"}
        |> phoenix_shaped_project()
        |> install()

      assert_has_notice(
        igniter,
        &String.contains?(
          &1,
          "{Telemetry.Metrics.ConsoleReporter, metrics: AshMetrics.metrics()}"
        )
      )

      assert_has_patch(igniter, "lib/test/application.ex", """
      + |      AshMetrics.Supervisor
      """)
    end
  end

  describe "the supervisor" do
    test "is added to the application's children after the repository" do
      children =
        phoenix_shaped_project()
        |> install()
        |> contents("lib/test/application.ex")

      [repo, supervisor] =
        Enum.map(["Test.Repo", "AshMetrics.Supervisor"], fn child ->
          assert {position, _length} = :binary.match(children, child),
                 "#{child} is not a child of the application"

          position
        end)

      assert supervisor > repo
    end

    test "is not added twice" do
      supervised =
        String.replace(
          @application,
          "      Test.Repo,\n",
          "      Test.Repo,\n      AshMetrics.Supervisor,\n"
        )

      %{"lib/test/application.ex" => supervised}
      |> phoenix_shaped_project()
      |> install()
      |> assert_unchanged("lib/test/application.ex")
    end
  end

  describe "running it again" do
    test "changes nothing" do
      phoenix_shaped_project()
      |> install()
      |> apply_igniter!()
      |> install()
      |> assert_unchanged()
    end
  end
end
