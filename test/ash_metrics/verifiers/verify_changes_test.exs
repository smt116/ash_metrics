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

      assert message =~ "action :update_status emits :nope, which this resource does not"
      assert message =~ "Declared metrics: :transitions"
    end

    test "the metric must be a counter" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: distribution(:transitions)),
                 quote(do: change(AshMetrics.increment_on_change(:transitions, :status)))
               )

      assert Exception.message(error) =~
               "emits :transitions, which is a distribution rather than a counter"
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

      assert message =~ "counts :state, which is not an attribute"
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

      assert Exception.message(error) =~ "the resource-level change emits :nope"
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

  describe "increment_on_write/2" do
    test "the counter must be declared" do
      assert [%DslError{path: [:actions, :update_status]} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:status])),
                 quote(do: change(AshMetrics.increment_on_write(:nope, :status)))
               )

      assert Exception.message(error) =~
               "action :update_status emits :nope, which this resource does not"
    end

    test "the metric must be a counter" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: distribution(:transitions)),
                 quote(do: change(AshMetrics.increment_on_write(:transitions, :status)))
               )

      assert Exception.message(error) =~
               "emits :transitions, which is a distribution rather than a counter"
    end

    test "the counted attribute must be an attribute" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:state])),
                 quote(do: change(AshMetrics.increment_on_write(:transitions, :state)))
               )

      assert Exception.message(error) =~ "counts :state, which is not an attribute"
    end

    test "the counted attribute must be a tag of the counter" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:assignee])),
                 quote(do: change(AshMetrics.increment_on_write(:transitions, :status)))
               )

      assert Exception.message(error) =~ "does not declare :status as a tag"
    end

    test "every other closed tag of the counter must name an attribute" do
      assert [%DslError{} = error] =
               errors(
                 quote(do: counter(:transitions, tags: [:status, region: [:eu, :us]])),
                 quote(do: change(AshMetrics.increment_on_write(:transitions, :status)))
               )

      assert Exception.message(error) =~
               "whose closed tag :region is not an attribute of this resource"
    end

    test "a valid declaration produces no errors" do
      assert errors(
               quote(do: counter(:transitions, tags: [:status])),
               quote(do: change(AshMetrics.increment_on_write(:transitions, :status)))
             ) == []
    end
  end

  describe "observe_elapsed/2" do
    test "the distribution must be declared" do
      assert [%DslError{path: [:actions, :update_status]} = error] =
               elapsed_errors(
                 quote(do: distribution(:time_to_resolve, unit: :millisecond)),
                 quote(do: change(AshMetrics.observe_elapsed(:nope, from: :inserted_at)))
               )

      message = Exception.message(error)

      assert message =~ "action :update_status emits :nope, which this resource does not declare"
      assert message =~ "Declare `distribution :nope`"
    end

    test "the metric must be a distribution" do
      assert [%DslError{} = error] =
               elapsed_errors(
                 quote(do: counter(:time_to_resolve)),
                 quote(
                   do: change(AshMetrics.observe_elapsed(:time_to_resolve, from: :inserted_at))
                 )
               )

      assert Exception.message(error) =~
               "emits :time_to_resolve, which is a counter rather than a distribution"
    end

    test "a conversion unit is not a time unit" do
      assert [%DslError{} = error] =
               elapsed_errors(
                 quote(do: distribution(:time_to_resolve, unit: {:native, :millisecond})),
                 quote(
                   do: change(AshMetrics.observe_elapsed(:time_to_resolve, from: :inserted_at))
                 )
               )

      message = Exception.message(error)

      assert message =~ "whose unit {:native, :millisecond} is not a time unit"
      assert message =~ "`unit: :second`, `:millisecond`, `:microsecond` or `:nanosecond`"
    end

    test "the default unit is not a time unit either" do
      assert [%DslError{} = error] =
               elapsed_errors(
                 quote(do: distribution(:time_to_resolve)),
                 quote(
                   do: change(AshMetrics.observe_elapsed(:time_to_resolve, from: :inserted_at))
                 )
               )

      assert Exception.message(error) =~ "whose unit :unit is not a time unit"
    end

    test "the timestamps must be attributes of the resource" do
      assert [%DslError{} = error] =
               elapsed_errors(
                 quote(do: distribution(:time_to_resolve, unit: :millisecond)),
                 quote(
                   do:
                     change(
                       AshMetrics.observe_elapsed(:time_to_resolve,
                         from: :inserted_at,
                         to: :nope
                       )
                     )
                 )
               )

      message = Exception.message(error)

      assert message =~ "measures an elapsed time with `to: :nope`, which is not an attribute"
      assert message =~ "Declared attributes: :id, :status, :inserted_at, :resolved_at"
    end

    test "the timestamps must be datetime attributes" do
      assert [%DslError{} = error] =
               elapsed_errors(
                 quote(do: distribution(:time_to_resolve, unit: :millisecond)),
                 quote(
                   do:
                     change(
                       AshMetrics.observe_elapsed(:time_to_resolve,
                         from: :status,
                         to: :resolved_at
                       )
                     )
                 )
               )

      message = Exception.message(error)

      assert message =~ "measures an elapsed time with `from: :status`, whose type Ash.Type.Atom"
      assert message =~ "Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec"
    end

    test "every closed tag of the distribution must name an attribute" do
      assert [%DslError{} = error] =
               elapsed_errors(
                 quote(
                   do:
                     distribution(:time_to_resolve,
                       unit: :millisecond,
                       tags: [region: [:eu, :us]]
                     )
                 ),
                 quote(
                   do: change(AshMetrics.observe_elapsed(:time_to_resolve, from: :inserted_at))
                 )
               )

      message = Exception.message(error)

      assert message =~ "whose closed tag :region is not an attribute of this resource"
      assert message =~ "emit that distribution by hand"
    end

    test "a valid declaration produces no errors" do
      assert elapsed_errors(
               quote(do: distribution(:time_to_resolve, unit: :millisecond, tags: [:status])),
               quote(
                 do:
                   change(
                     AshMetrics.observe_elapsed(:time_to_resolve,
                       from: :inserted_at,
                       to: :resolved_at
                     )
                   )
               )
             ) == []
    end
  end

  # An `update` action carrying `change`, on a resource with a `status`
  # attribute, which is what every declaration under test is attached to.
  defp errors(metrics, change, attributes \\ []) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(metrics)
        end
      end,
      [quote(do: attribute(:status, :atom))] ++ attributes,
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

  # The same resource with the two timestamps an elapsed time is measured
  # between.
  defp elapsed_errors(metrics, change) do
    errors(metrics, change, [
      quote(do: attribute(:inserted_at, :utc_datetime_usec)),
      quote(do: attribute(:resolved_at, :utc_datetime_usec))
    ])
  end
end
