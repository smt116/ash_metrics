defmodule Mix.Tasks.AshMetrics.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # `Igniter.Test.test_project/1` names the generated application `:test`, so
  # that is the prefix and the `otp_app` the installer should derive.
  describe "configuration" do
    test "writes the prefix and the otp_app of the application" do
      test_project()
      |> Igniter.compose_task("ash_metrics.install", [])
      |> assert_creates("config/config.exs", """
      import Config
      config :ash_metrics, prefix: "test", otp_app: :test
      """)
    end

    test "adds the keys an application already configured is missing" do
      test_project(
        files: %{
          "config/config.exs" => """
          import Config

          config :ash_metrics, prefix: "custom"
          """
        }
      )
      |> Igniter.compose_task("ash_metrics.install", [])
      |> assert_has_patch("config/config.exs", """
      + |config :ash_metrics, prefix: "custom", otp_app: :test
      """)
    end

    test "leaves a prefix the application has already chosen alone" do
      igniter =
        test_project(
          files: %{
            "config/config.exs" => """
            import Config

            config :ash_metrics, prefix: "chosen", otp_app: :chosen
            """
          }
        )
        |> Igniter.compose_task("ash_metrics.install", [])

      assert_unchanged(igniter, "config/config.exs")
    end

    test "imports the formatter configuration of the package" do
      test_project()
      |> Igniter.compose_task("ash_metrics.install", [])
      |> assert_has_patch(".formatter.exs", """
      + |  import_deps: [:ash_metrics]
      """)
    end
  end

  describe "the optional keys" do
    test "are printed with their defaults" do
      igniter =
        test_project()
        |> Igniter.compose_task("ash_metrics.install", [])

      assert_has_notice(igniter, &String.contains?(&1, "backend: AshMetrics.Backend.Noop"))
      assert_has_notice(igniter, &String.contains?(&1, "poller: AshMetrics.Poller.GenServer"))
      assert_has_notice(igniter, &String.contains?(&1, "tenant_source: nil"))
    end
  end

  describe "running it again" do
    test "changes nothing" do
      test_project()
      |> Igniter.compose_task("ash_metrics.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("ash_metrics.install", [])
      |> assert_unchanged()
    end
  end
end
