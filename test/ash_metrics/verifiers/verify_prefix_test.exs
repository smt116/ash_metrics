defmodule AshMetrics.Verifiers.VerifyPrefixTest do
  # Removes the configured prefix and captures stderr, so it cannot run
  # alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Test.Compiler
  alias Spark.Error.DslError

  setup do
    original = Application.get_env(:ash_metrics, :prefix)
    Application.delete_env(:ash_metrics, :prefix)

    on_exit(fn -> Application.put_env(:ash_metrics, :prefix, original) end)

    :ok
  end

  test "a resource declaring metrics does not compile without a prefix" do
    assert [%DslError{path: [:metrics]} = error] = Compiler.dsl_errors(counter())

    message = Exception.message(error)

    assert message =~ "`prefix` must be set to a non-empty string"
    assert message =~ ~s(config :ash_metrics, prefix: "myapp")
    assert message =~ "got: nil"
  end

  test "an empty prefix is refused too" do
    Application.put_env(:ash_metrics, :prefix, "")

    assert [%DslError{} = error] = Compiler.dsl_errors(counter())

    assert Exception.message(error) =~ ~s(got: "")
  end

  test "a non-string prefix is refused too" do
    Application.put_env(:ash_metrics, :prefix, :myapp)

    assert [%DslError{} = error] = Compiler.dsl_errors(counter())

    assert Exception.message(error) =~ "got: :myapp"
  end

  test "a resource verifies cleanly once a prefix is configured" do
    Application.put_env(:ash_metrics, :prefix, "test")

    assert Compiler.dsl_errors(counter()) == []
  end

  defp counter do
    quote do
      metrics do
        counter :delivery, tags: [status: [:sent]]
      end
    end
  end
end
