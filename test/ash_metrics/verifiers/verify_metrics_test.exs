defmodule AshMetrics.Verifiers.VerifyMetricsTest.ScanSummary do
  @moduledoc false
  # The implementation the custom aggregate under test names; never run.
  use Ash.Resource.Aggregate.CustomAggregate
end

defmodule AshMetrics.Verifiers.VerifyMetricsTest.Choice do
  @moduledoc false
  # A union behind an `Ash.Type.NewType`.
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [types: [name: [type: :string], size: [type: :integer]]]
end

defmodule AshMetrics.Verifiers.VerifyMetricsTest.Pair do
  @moduledoc false
  # A tuple behind an `Ash.Type.NewType`.
  use Ash.Type.NewType,
    subtype_of: :tuple,
    constraints: [fields: [a: [type: :string], b: [type: :integer]]]
end

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

  test "a path may descend one or two embedded resources" do
    assert errors(
             quote do
               counter :delivery,
                 tags: [
                   state: [path: [:location, :state]],
                   shipping_state: [path: [:location, :shipping_address, :state]]
                 ]
             end,
             [location()]
           ) == []
  end

  test "a path through a NewType wrapping an embedded resource is accepted" do
    assert errors(
             quote(do: counter(:delivery, tags: [state: [path: [:origin, :state]]])),
             [quote(do: attribute(:origin, AshMetrics.Test.LocationType))]
           ) == []
  end

  test "a path starts at an attribute, calculation or aggregate of the resource" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [state: [path: [:nope, :state]]])),
               [location()]
             )

    message = Exception.message(error)

    assert message =~
             "the path of the tag :state of counter :delivery starts at :nope, " <>
               "which is not an attribute, calculation or aggregate of this resource"

    assert message =~
             "Declared attributes: :id, :status, :location; calculations: none; " <>
               "aggregates: none"
  end

  test "a path may only descend through an embedded resource" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [state: [path: [:status, :name]]])))

    message = Exception.message(error)

    assert message =~ "goes through :status, whose type Ash.Type.Atom is not an embedded"
    assert message =~ "descends through embedded attributes only"
  end

  test "every later segment is an attribute of the embedded resource before it" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [state: [path: [:location, :nope]]])),
               [location()]
             )

    message = Exception.message(error)

    assert message =~ "names :nope, which is not an attribute of AshMetrics.Test.Location"
    assert message =~ "Declared attributes: :state, :shipping_address"
  end

  test "a path may not go through a list" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [state: [path: [:stops, :state]]])),
               [quote(do: attribute(:stops, {:array, AshMetrics.Test.Address}))]
             )

    message = Exception.message(error)

    assert message =~ "goes through :stops, whose type"
    assert message =~ "A path cannot go through a list"
  end

  test "a path may not end at an embedded resource" do
    assert [%DslError{} = error] =
             errors(
               quote(
                 do: counter(:delivery, tags: [where: [path: [:location, :shipping_address]]])
               ),
               [location()]
             )

    message = Exception.message(error)

    assert message =~
             "ends at :shipping_address, whose type AshMetrics.Test.Address is an " <>
               "embedded resource"

    assert message =~ "End the path at one of its attributes: :state"
  end

  test "a path may not end at a map" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [payload: [path: [:payload]]])),
               [quote(do: attribute(:payload, :map))]
             )

    assert Exception.message(error) =~
             "ends at :payload, whose type Ash.Type.Map holds several values"
  end

  test "an empty path is refused" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [state: [path: []]])))

    assert Exception.message(error) =~
             "counter :delivery declares an empty path for the tag :state"
  end

  test "a tag naming an embedded attribute without a path is refused" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [:location])), [location()])

    message = Exception.message(error)

    assert message =~
             "counter :delivery declares the tag :location, whose attribute has " <>
               "the type AshMetrics.Test.Location"

    assert message =~ "declare `location: [path: [:location, ...]]`"
  end

  test "a tag naming a map attribute without a path is refused" do
    assert [%DslError{} = error] =
             errors(
               quote(do: distribution(:send_latency, tags: [:payload])),
               [quote(do: attribute(:payload, :map))]
             )

    message = Exception.message(error)

    assert message =~
             "distribution :send_latency declares the tag :payload, whose attribute " <>
               "has the type Ash.Type.Map"

    assert message =~ "no path reaches inside that type"
    refute message =~ "path: [:payload"
  end

  test "a tag naming a list attribute without a path is refused" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [:labels])),
               [quote(do: attribute(:labels, {:array, :string}))]
             )

    assert Exception.message(error) =~
             "counter :delivery declares the tag :labels, whose attribute has the " <>
               "type {:array, Ash.Type.String}, a list. A tag carries one value."
  end

  test "a path ending at a list attribute is refused" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [l: [path: [:labels]]])),
               [quote(do: attribute(:labels, {:array, :string}))]
             )

    assert Exception.message(error) =~ "goes through :labels, whose type"
  end

  test "a tag naming a union attribute without a path is refused" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [:choice])), [union()])

    message = Exception.message(error)

    assert message =~
             "counter :delivery declares the tag :choice, whose attribute has the " <>
               "type Ash.Type.Union"

    assert message =~ "no path reaches inside that type"
  end

  test "a tag naming a tuple attribute without a path is refused" do
    assert [%DslError{} = error] =
             errors(quote(do: counter(:delivery, tags: [:pair])), [tuple()])

    message = Exception.message(error)

    assert message =~
             "counter :delivery declares the tag :pair, whose attribute has the " <>
               "type Ash.Type.Tuple"

    assert message =~ "no path reaches inside that type"
  end

  test "a path ending at a union or a tuple attribute is refused" do
    assert [%DslError{} = union_error] =
             errors(quote(do: counter(:delivery, tags: [c: [path: [:choice]]])), [union()])

    assert Exception.message(union_error) =~
             "ends at :choice, whose type Ash.Type.Union wraps its value. A tag " <>
               "carries one value, and no path reaches inside that type."

    assert [%DslError{} = tuple_error] =
             errors(quote(do: counter(:delivery, tags: [p: [path: [:pair]]])), [tuple()])

    assert Exception.message(tuple_error) =~
             "ends at :pair, whose type Ash.Type.Tuple wraps its value."
  end

  test "a path going through a union or a tuple attribute is refused" do
    assert [%DslError{} = union_error] =
             errors(
               quote(do: counter(:delivery, tags: [c: [path: [:choice, :name]]])),
               [union()]
             )

    assert Exception.message(union_error) =~
             "goes through :choice, whose type Ash.Type.Union is not an embedded resource"

    assert [%DslError{} = tuple_error] =
             errors(quote(do: counter(:delivery, tags: [p: [path: [:pair, :a]]])), [tuple()])

    assert Exception.message(tuple_error) =~
             "goes through :pair, whose type Ash.Type.Tuple is not an embedded resource"
  end

  test "a NewType wrapping a union or a tuple is refused as the bare type is" do
    new_types = [
      quote(do: attribute(:choice, AshMetrics.Verifiers.VerifyMetricsTest.Choice)),
      quote(do: attribute(:pair, AshMetrics.Verifiers.VerifyMetricsTest.Pair))
    ]

    for tag <- [:choice, :pair] do
      assert [%DslError{} = error] =
               errors(quote(do: counter(:delivery, tags: [unquote(tag)])), new_types)

      assert Exception.message(error) =~ "declares the tag #{inspect(tag)}"
      assert Exception.message(error) =~ "no path reaches inside that type"
    end

    assert [%DslError{} = union_error] =
             errors(quote(do: counter(:delivery, tags: [c: [path: [:choice]]])), new_types)

    assert Exception.message(union_error) =~
             "ends at :choice, whose type Ash.Type.Union wraps its value."

    assert [%DslError{} = tuple_error] =
             errors(quote(do: counter(:delivery, tags: [p: [path: [:pair]]])), new_types)

    assert Exception.message(tuple_error) =~
             "ends at :pair, whose type Ash.Type.Tuple wraps its value."
  end

  describe "a tag read from a calculation" do
    test "is accepted without a path, and with a path into an embedded result" do
      assert calculation_errors(
               quote(
                 do:
                   counter(:delivery,
                     tags: [:size, :weight_class, state: [path: [:route, :state]]]
                   )
               )
             ) == []
    end

    test "is refused when the calculation has a required argument" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [:above])))

      message = Exception.message(error)

      assert message =~
               "counter :delivery reads the tag :above from the calculation :above, " <>
                 "whose argument :threshold is required and has no default"

      assert message =~ "give the argument a default or `allow_nil? true`"
    end

    test "is refused with a path when the calculation has a required argument" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [a: [path: [:above]]])))

      assert Exception.message(error) =~ "whose argument :threshold is required"
    end

    test "is refused without a path when the calculation returns a list" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [:labels])))

      assert Exception.message(error) =~
               "counter :delivery declares the tag :labels, whose calculation has " <>
                 "the type {:array, Ash.Type.String}, a list. A tag carries one value."
    end

    test "is refused without a path when the calculation returns a map" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [:payload])))

      message = Exception.message(error)

      assert message =~
               "counter :delivery declares the tag :payload, whose calculation has " <>
                 "the type Ash.Type.Map"

      assert message =~ "no path reaches inside that type"
      assert message =~ "read it from a calculation that returns the single value"
    end

    test "is refused without a path when the calculation returns a union" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [:choice])))

      message = Exception.message(error)

      assert message =~
               "counter :delivery declares the tag :choice, whose calculation has " <>
                 "the type Ash.Type.Union"

      assert message =~ "no path reaches inside that type"
    end

    test "is refused without a path when the calculation returns an embedded resource" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [:route])))

      message = Exception.message(error)

      assert message =~ "whose calculation has the type AshMetrics.Test.Location"
      assert message =~ "declare `route: [path: [:route, ...]]`"
    end

    test "is refused when a path goes through a list calculation" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [l: [path: [:labels]]])))

      assert Exception.message(error) =~ "goes through :labels, whose type"
    end

    test "is refused when a path ends at an embedded calculation" do
      assert [%DslError{} = error] =
               calculation_errors(quote(do: counter(:delivery, tags: [r: [path: [:route]]])))

      assert Exception.message(error) =~
               "ends at :route, whose type AshMetrics.Test.Location is an embedded resource"
    end
  end

  describe "a tag read from an aggregate" do
    test "is accepted for a scalar aggregate, with or without a path" do
      assert aggregate_errors(
               quote(
                 do:
                   counter(:delivery,
                     tags: [:scan_count, :scanned, :first_scan, first: [path: [:first_scan]]]
                   )
               )
             ) == []
    end

    test "is refused when a path goes through a count aggregate" do
      assert [%DslError{} = error] =
               aggregate_errors(
                 quote(do: counter(:delivery, tags: [c: [path: [:scan_count, :state]]]))
               )

      assert Exception.message(error) =~
               "goes through :scan_count, whose type Ash.Type.Integer is not an embedded resource"
    end

    test "is refused for a list aggregate" do
      assert [%DslError{} = error] =
               aggregate_errors(quote(do: counter(:delivery, tags: [:scan_ids])))

      assert Exception.message(error) =~
               "counter :delivery reads the tag :scan_ids from the aggregate " <>
                 ":scan_ids, which is a list aggregate. A tag carries one value."
    end

    test "is refused for a list aggregate at the start of a path" do
      assert [%DslError{} = error] =
               aggregate_errors(quote(do: counter(:delivery, tags: [ids: [path: [:scan_ids]]])))

      assert Exception.message(error) =~ "which is a list aggregate"
    end

    test "is refused for a custom aggregate of a map type" do
      assert [%DslError{} = error] =
               aggregate_errors(quote(do: counter(:delivery, tags: [:scan_summary])))

      assert Exception.message(error) =~
               "declares the tag :scan_summary, whose aggregate has the type Ash.Type.Map"
    end

    test "is accepted over a relationship path of two hops" do
      assert aggregate_errors(
               quote(do: counter(:delivery, tags: [:sibling_scans, :sibling_weight]))
             ) == []
    end

    test "resolves the type of a first aggregate over a relationship path of two hops" do
      assert [%DslError{} = error] =
               aggregate_errors(quote(do: counter(:delivery, tags: [:sibling_destination])))

      message = Exception.message(error)

      assert message =~
               "declares the tag :sibling_destination, whose aggregate has the type " <>
                 "AshMetrics.Test.Location"

      assert message =~ "declare `sibling_destination: [path: [:sibling_destination, ...]]`"
    end

    test "is accepted for a first aggregate of a field that is itself an aggregate" do
      assert aggregate_errors(quote(do: counter(:delivery, tags: [:sibling_scan_count]))) == []
    end

    test "is refused for a first aggregate of a list field" do
      assert [%DslError{} = error] =
               aggregate_errors(quote(do: counter(:delivery, tags: [:first_readings])))

      assert Exception.message(error) =~
               "declares the tag :first_readings, whose aggregate has the type " <>
                 "{:array, Ash.Type.Integer}, a list. A tag carries one value."
    end

    test "is refused for a first aggregate of a map field" do
      assert [%DslError{} = error] =
               aggregate_errors(quote(do: counter(:delivery, tags: [:first_payload])))

      assert Exception.message(error) =~
               "declares the tag :first_payload, whose aggregate has the type Ash.Type.Map"
    end
  end

  test "a path that starts at nothing lists the calculations and aggregates" do
    assert [%DslError{} = error] =
             aggregate_errors(quote(do: counter(:delivery, tags: [state: [path: [:nope]]])))

    message = Exception.message(error)

    assert message =~
             "starts at :nope, which is not an attribute, calculation or aggregate " <>
               "of this resource"

    assert message =~
             "Declared attributes: :id, :status; calculations: none; aggregates: " <>
               ":scan_count, :scanned, :first_scan, :first_payload, :first_readings, " <>
               ":sibling_scans, :sibling_weight, :sibling_scan_count, " <>
               ":sibling_destination, :scan_ids, :scan_summary"
  end

  test "a path tag is checked against the reserved tags like any other" do
    assert [%DslError{} = error] =
             errors(
               quote(do: counter(:delivery, tags: [tenant: [path: [:location, :state]]])),
               [location()]
             )

    assert Exception.message(error) =~ "declares the tag :tenant, which is reserved"
  end

  test "a path tag may not be declared twice" do
    assert [%DslError{} = error] =
             errors(
               quote(
                 do:
                   counter(:delivery,
                     tags: [:state, state: [path: [:location, :state]]]
                   )
               ),
               [location()]
             )

    assert Exception.message(error) =~ "declares the tag :state more than once"
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

  # The embedded attribute the tag paths under test descend into.
  defp location, do: quote(do: attribute(:location, AshMetrics.Test.Location))

  defp union do
    quote do
      attribute :choice, :union,
        constraints: [types: [name: [type: :string], size: [type: :integer]]]
    end
  end

  defp tuple do
    quote do
      attribute :pair, :tuple, constraints: [fields: [a: [type: :string], b: [type: :integer]]]
    end
  end

  # A throwaway resource declaring calculations of every shape a tag may or may
  # not read from.
  defp calculation_errors(declarations) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end,
      [quote(do: attribute(:status, :atom))],
      [
        quote do
          calculations do
            calculate :size, :atom, expr(:small)

            calculate :weight_class, :atom, expr(:light) do
              argument :threshold, :integer, default: 20
            end

            calculate :above, :boolean, expr(true) do
              argument :threshold, :integer, allow_nil?: false
            end

            calculate :labels, {:array, :string}, fn records, _context ->
              Enum.map(records, fn _record -> [] end)
            end

            calculate :payload, :map, fn records, _context ->
              Enum.map(records, fn _record -> %{} end)
            end

            calculate :route, AshMetrics.Test.Location, fn records, _context ->
              Enum.map(records, fn _record -> nil end)
            end

            calculate :choice,
                      :union,
                      fn records, _context -> Enum.map(records, fn _record -> nil end) end,
                      constraints: [types: [name: [type: :string], size: [type: :integer]]]
          end
        end
      ]
    )
  end

  # A throwaway resource on a data layer that supports aggregates, declaring
  # aggregates of every shape a tag may or may not read from over
  # `AshMetrics.Test.ParcelScan`.
  defp aggregate_errors(declarations) do
    Compiler.dsl_errors(
      quote do
        metrics do
          unquote(declarations)
        end
      end,
      [quote(do: attribute(:status, :atom))],
      [
        quote do
          relationships do
            has_many :scans, AshMetrics.Test.ParcelScan, destination_attribute: :parcel_id
          end
        end,
        quote do
          aggregates do
            count :scan_count, :scans
            exists :scanned, :scans
            first :first_scan, :scans, :station
            first :first_payload, :scans, :payload
            first :first_readings, :scans, :readings
            count :sibling_scans, [:scans, :parcel]
            first :sibling_weight, [:scans, :parcel], :weight
            first :sibling_scan_count, [:scans, :parcel], :scan_count
            first :sibling_destination, [:scans, :parcel], :destination
            list :scan_ids, :scans, :id

            custom :scan_summary, :scans, :map do
              implementation AshMetrics.Verifiers.VerifyMetricsTest.ScanSummary
            end
          end
        end
      ],
      Ash.DataLayer.Ets
    )
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
