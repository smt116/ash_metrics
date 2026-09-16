defmodule AshMetrics.ConfigTest do
  # Mutates the application environment, so it cannot share it with other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Config

  setup do
    original = Application.get_all_env(:ash_metrics)

    on_exit(fn ->
      Enum.each(
        [
          :prefix,
          :otp_app,
          :outcome_tag,
          :name_builder,
          :tag_extractor,
          :backend,
          :poller,
          :tenant_source
        ],
        fn key ->
          case Keyword.fetch(original, key) do
            {:ok, value} -> Application.put_env(:ash_metrics, key, value)
            :error -> Application.delete_env(:ash_metrics, key)
          end
        end
      )
    end)

    :ok
  end

  describe "prefix!/0" do
    test "returns the configured prefix" do
      assert Config.prefix!() == "test"
    end

    test "returns an overridden prefix" do
      Application.put_env(:ash_metrics, :prefix, "other")

      assert Config.prefix!() == "other"
    end

    test "raises showing the config snippet when it is missing" do
      Application.delete_env(:ash_metrics, :prefix)

      error = assert_raise ArgumentError, fn -> Config.prefix!() end

      assert error.message =~ "`prefix` must be set to a non-empty string"
      assert error.message =~ ~s(config :ash_metrics, prefix: "myapp")
      assert error.message =~ "got: nil"
    end

    test "raises when it is an empty string" do
      Application.put_env(:ash_metrics, :prefix, "")

      assert_raise ArgumentError, ~r/must be set to a non-empty string/, fn ->
        Config.prefix!()
      end
    end

    test "raises when it is not a string" do
      Application.put_env(:ash_metrics, :prefix, :myapp)

      error = assert_raise ArgumentError, fn -> Config.prefix!() end

      assert error.message =~ "got: :myapp"
    end
  end

  describe "otp_app!/0" do
    test "returns the configured otp_app" do
      assert Config.otp_app!() == :ash_metrics
    end

    test "raises showing the config snippet when it is missing" do
      Application.delete_env(:ash_metrics, :otp_app)

      error = assert_raise ArgumentError, fn -> Config.otp_app!() end

      assert error.message =~ "`otp_app` must be set to an application name"
      assert error.message =~ "config :ash_metrics, otp_app: :my_app"
    end

    test "raises when it is not an atom" do
      Application.put_env(:ash_metrics, :otp_app, "my_app")

      error = assert_raise ArgumentError, fn -> Config.otp_app!() end

      assert error.message =~ ~s(got: "my_app")
    end
  end

  describe "tenant_source/0" do
    test "returns the configured tenant source" do
      assert Config.tenant_source() == AshMetrics.Test.Tenants
    end

    test "returns nil when there is none" do
      Application.delete_env(:ash_metrics, :tenant_source)

      assert Config.tenant_source() == nil
    end
  end

  describe "tenant_source!/0" do
    test "returns the configured tenant source" do
      assert Config.tenant_source!() == AshMetrics.Test.Tenants
    end

    test "returns an overridden tenant source" do
      Application.put_env(:ash_metrics, :tenant_source, MyApp.Tenants)

      assert Config.tenant_source!() == MyApp.Tenants
    end

    test "raises showing the config snippet when it is missing" do
      Application.delete_env(:ash_metrics, :tenant_source)

      error = assert_raise ArgumentError, fn -> Config.tenant_source!() end

      assert error.message =~ "`tenant_source` must be set to a module implementing"
      assert error.message =~ "config :ash_metrics, tenant_source: MyApp.Tenants"
      assert error.message =~ "got: nil"
    end

    test "raises when it is not a module" do
      Application.put_env(:ash_metrics, :tenant_source, "MyApp.Tenants")

      error = assert_raise ArgumentError, fn -> Config.tenant_source!() end

      assert error.message =~ ~s(got: "MyApp.Tenants")
    end
  end

  describe "defaults" do
    test "outcome_tag/0 defaults to :outcome" do
      assert Config.outcome_tag() == :outcome
    end

    test "name_builder/0 defaults to the bundled builder" do
      assert Config.name_builder() == AshMetrics.NameBuilder.Default
    end

    test "tag_extractor/0 defaults to the bundled extractor" do
      assert Config.tag_extractor() == AshMetrics.TagExtractor.Default
    end

    test "backend/0 defaults to the noop backend" do
      assert Config.backend() == AshMetrics.Backend.Noop
    end

    test "poller/0 defaults to the bundled GenServer poller" do
      assert Config.poller() == AshMetrics.Poller.GenServer
    end
  end

  describe "overrides" do
    test "outcome_tag/0 can be overridden" do
      Application.put_env(:ash_metrics, :outcome_tag, :result)

      assert Config.outcome_tag() == :result
    end

    test "name_builder/0 can be overridden" do
      Application.put_env(:ash_metrics, :name_builder, MyApp.NameBuilder)

      assert Config.name_builder() == MyApp.NameBuilder
    end

    test "tag_extractor/0 can be overridden" do
      Application.put_env(:ash_metrics, :tag_extractor, MyApp.TagExtractor)

      assert Config.tag_extractor() == MyApp.TagExtractor
    end

    test "backend/0 can be overridden" do
      Application.put_env(:ash_metrics, :backend, MyApp.Backend)

      assert Config.backend() == MyApp.Backend
    end

    test "poller/0 can be overridden" do
      Application.put_env(:ash_metrics, :poller, MyApp.Poller)

      assert Config.poller() == MyApp.Poller
    end
  end
end
