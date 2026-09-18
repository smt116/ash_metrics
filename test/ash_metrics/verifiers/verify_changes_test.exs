defmodule AshMetrics.Verifiers.VerifyChangesTest do
  # Captures the compiler's stderr, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.Ticket
  alias Spark.Error.DslError

  describe "increment_on_change/2" do
    test "the counter must be declared" do
      assert [%DslError{path: [:actions, :update_status]} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:status])),
                 quote(do: change(AshMetrics.increment_on_change(:nope, :status)))
               )

      message = Exception.message(error)

      assert message =~ "action :update_status increments :nope, which this resource"
      assert message =~ "Declared metrics: :transitions"
    end

    test "the metric must be a counter" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: distribution(:transitions)),
                 quote(do: change(AshMetrics.increment_on_change(:transitions, :status)))
               )

      assert Exception.message(error) =~
               "increments :transitions, which is a distribution rather than a counter"
    end

    test "a gauge is refused too" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: gauge(:transitions)),
                 quote(do: change(AshMetrics.increment_on_change(:transitions, :status)))
               )

      assert Exception.message(error) =~ "which is a gauge rather than a counter"
    end

    test "the counted attribute must be an attribute" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:state])),
                 quote(do: change(AshMetrics.increment_on_change(:transitions, :state)))
               )

      message = Exception.message(error)

      assert message =~ "counts changes of :state, which is not an attribute"
      assert message =~ "Declared attributes: :id, :status"
    end

    test "the counted attribute must be a tag of the counter" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:assignee])),
                 quote(do: change(AshMetrics.increment_on_change(:transitions, :status)))
               )

      message = Exception.message(error)

      assert message =~ "does not declare :status as a tag"
      assert message =~ "Declared tags: :assignee"
    end

    test "every other closed tag of the counter must name an attribute" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:status, region: [:eu, :us]])),
                 quote(do: change(AshMetrics.increment_on_change(:transitions, :status)))
               )

      message = Exception.message(error)

      assert message =~ "whose closed tag :region is not an attribute of this resource"
      assert message =~ "no emission could ever carry it"
    end

    test "an open tag that names no attribute is left alone" do
      assert errors(
               quote(do: counter(:transitions, tags: [:status, :region])),
               quote(do: change(AshMetrics.increment_on_change(:transitions, :status)))
             ) == []
    end

    test "a resource-level change is checked and named as one" do
      assert [%DslError{path: [:changes]} = error] =
               Compiler.dsl_errors(
                 quote do
                   metrics do
                     counter :transitions, tags: [:status]
                   end
                 end,
                 [quote(do: attribute(:status, :atom))],
                 [
                   quote do
                     changes do
                       change AshMetrics.increment_on_change(:nope, :status)
                     end
                   end
                 ]
               )

      assert Exception.message(error) =~ "the resource-level change increments :nope"
    end

    test "a change of another kind is left alone" do
      assert errors(
               quote(do: counter(:transitions, tags: [:status])),
               quote(do: change(set_attribute(:status, :open)))
             ) == []
    end

    test "the support resource declares valid changes" do
      assert Compiler.dsl_errors_for(Ticket) == []
    end
  end

  # An `update` action carrying `change`, on a resource with a `status`
  # attribute, which is what every declaration under test is attached to.
  defp errors(metrics, change) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(metrics)
        end
      end,
      [quote(do: attribute(:status, :atom))],
      [
        quote do
          actions do
            update :update_status do
              require_atomic? false

              unquote(change)
            end
          end
        end
      ]
    )
  end
end
