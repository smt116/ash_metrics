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
                 counter :delivery, tags: [status: [:sent]]
                 distribution :delivery
               end
             )

    assert Exception.message(error) =~ "metric :delivery is declared more than once"
  end

  test "a closed tag must declare at least one value" do
    assert [%DslError{} = error] = errors(quote(do: counter(:delivery, tags: [status: []])))

    message = Exception.message(error)

    assert message =~ "counter :delivery declares no values for the tag :status"
    assert message =~ "A closed tag lists at least one value."
  end

  test "a closed tag may not declare the same value twice" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [status: [:sent, :error, :sent]])))

    assert Exception.message(error) =~
             "counter :delivery declares the value :sent of the tag :status more than once"
  end

  test "a closed tag of a distribution is checked too" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, tags: [provider: []])))

    assert Exception.message(error) =~
             "distribution :send_latency declares no values for the tag :provider"
  end

  test "a counter may not declare a tag key twice across the two forms" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [:status, status: [:sent]])))

    assert Exception.message(error) =~
             "counter :delivery declares the tag :status more than once"
  end

  test "a counter may not declare the same tag twice" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [:provider, :provider])))

    assert Exception.message(error) =~
             "counter :delivery declares the tag :provider more than once"
  end

  test "a distribution may not declare the same tag twice" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, tags: [:provider, :provider])))

    assert Exception.message(error) =~
             "distribution :send_latency declares the tag :provider more than once"
  end

  test "a tag the extractor supplies is reserved" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [:tenant, status: [:sent]])))

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

  test "a suffix may not contain a dot" do
    assert [%DslError{} = error] =
             errors(quote(do: distribution(:send_latency, suffix: :"a.b")))

    message = Exception.message(error)

    assert message =~ ~s(distribution :send_latency declares the suffix :"a.b")
    assert message =~ "non-empty atom holding no dot"
  end

  test "a suffix may not be empty" do
    assert [%DslError{} = error] = errors(quote(do: distribution(:send_latency, suffix: :"")))

    assert Exception.message(error) =~ ~s(declares the suffix :"")
  end

  test "a gauge shares the metric namespace with a counter" do
    assert [%DslError{path: [:metrics, :backlog]} = error] =
             errors(
               quote do
                 counter :backlog, tags: [status: [:sent]]
                 gauge :backlog
               end
             )

    assert Exception.message(error) =~ "metric :backlog is declared more than once"
  end

  test "a gauge may only group by attributes of the resource" do
    assert [%DslError{} = error] = errors(quote(do: gauge(:backlog, group_by: [:status, :nope])))

    message = Exception.message(error)

    assert message =~ "gauge :backlog groups by :nope, which is not an attribute"
    assert message =~ "Declared attributes: :id, :status"
  end

  test "a gauge may not group by the same attribute twice" do
    assert [%DslError{} = error] =
             errors(quote(do: gauge(:backlog, group_by: [:status, :status])))

    assert Exception.message(error) =~ "gauge :backlog groups by :status more than once"
  end

  test "a gauge may group by an attribute the tag extractor also supplies" do
    assert errors(quote(do: gauge(:backlog, group_by: [:tenant])), [
             quote(do: attribute(:tenant, :string))
           ]) == []
  end

  test "a valid gauge produces no errors" do
    # `context: Elixir` because `expr/1` turns bare names into references to
    # attributes, and a hygienic `status` quoted here is a variable of this test
    # module instead.
    assert errors(
             quote context: Elixir do
               gauge :backlog,
                 filter: expr(status == :pending),
                 group_by: [:status],
                 period: 1_000,
                 description: "Pending jobs"
             end
           ) == []
  end

  test "a valid declaration produces no errors" do
    assert errors(
             quote do
               counter :delivery, tags: [:provider, status: [:sent, :error]]

               distribution :send_latency,
                 unit: {:native, :millisecond},
                 buckets: [10, 50.5, 100],
                 tags: [{:provider, [:ses]}, :template]
             end
           ) == []
  end

  test "a counter with no tags at all is valid" do
    assert errors(quote(do: counter(:delivery))) == []
  end

  test "the support resources declare valid metrics" do
    assert Compiler.dsl_errors(quote(do: nil)) == []
    assert length(Info.metrics(Delivery)) == 2
  end

  # The throwaway resource declares a `status` attribute, so that a gauge has
  # something valid to group by; pass `attributes` for anything else it needs.
  defp errors(declarations, attributes \\ []) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end,
      [quote(do: attribute(:status, :atom))] ++ attributes
    )
  end
end
