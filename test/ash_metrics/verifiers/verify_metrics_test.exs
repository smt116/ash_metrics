defmodule AshMetrics.Verifiers.VerifyMetricsTest do
  # Captures the compiler's stderr, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Info
  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.Delivery
  alias Spark.Error.DslError

  test "a metric name may not be declared twice" do
    assert [%DslError{path: [:metrics, :delivery]} = error] =
             errors(
               quote do
                 counter :delivery, outcomes: [:sent]
                 distribution :delivery
               end
             )

    assert Exception.message(error) =~ "metric :delivery is declared more than once"
  end

  test "a counter must declare at least one outcome" do
    assert [%DslError{} = error] = errors(quote(do: counter(:delivery, outcomes: [])))

    message = Exception.message(error)

    assert message =~ "counter :delivery declares no outcomes"
    assert message =~ "permitted values of the :outcome tag"
  end

  test "a counter may not declare the same outcome twice" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, outcomes: [:sent, :error, :sent])))

    assert Exception.message(error) =~
             "counter :delivery declares the outcome :sent more than once"
  end

  test "a counter may not declare the same tag twice" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, outcomes: [:sent], tags: [:provider, :provider]))
             )

    assert Exception.message(error) =~
             "counter :delivery declares the tag :provider more than once"
  end

  test "a distribution may not declare the same tag twice" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, tags: [:provider, :provider])))

    assert Exception.message(error) =~
             "distribution :send_latency declares the tag :provider more than once"
  end

  test "the outcome tag is reserved" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, outcomes: [:sent], tags: [:outcome])))

    message = Exception.message(error)

    assert message =~ "declares the tag :outcome, which is reserved"
    assert message =~ "config :ash_metrics, outcome_tag: :outcome"
  end

  test "a tag the extractor supplies is reserved" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, outcomes: [:sent], tags: [:tenant])))

    message = Exception.message(error)

    assert message =~ "declares the tag :tenant, which is reserved"
    assert message =~ "AshMetrics.TagExtractor.Default"
  end

  test "buckets must ascend" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, buckets: [50, 10])))

    message = Exception.message(error)

    assert message =~ "declares buckets [50, 10]"
    assert message =~ "non-empty, strictly ascending list of positive numbers"
  end

  test "buckets must ascend strictly" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, buckets: [10, 10, 50])))

    assert Exception.message(error) =~ "declares buckets [10, 10, 50]"
  end

  test "buckets must be positive" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, buckets: [0, 10])))

    assert Exception.message(error) =~ "declares buckets [0, 10]"
  end

  test "an empty bucket list is refused" do
    assert [%DslError{} = error] = errors(quote(do: distribution(:send_latency, buckets: [])))

    assert Exception.message(error) =~ "declares buckets []"
  end

  test "a valid declaration produces no errors" do
    assert errors(
             quote do
               counter :delivery, outcomes: [:sent, :error], tags: [:provider]
               distribution :send_latency, unit: {:native, :millisecond}, buckets: [10, 50.5, 100]
             end
           ) == []
  end

  test "the support resources declare valid metrics" do
    assert Compiler.dsl_errors(quote(do: nil)) == []
    assert length(Info.metrics(Delivery)) == 2
  end

  defp errors(declarations) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end
    )
  end
end
