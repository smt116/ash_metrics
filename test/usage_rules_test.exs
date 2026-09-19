defmodule AshMetrics.UsageRulesTest do
  @moduledoc """
  Checks that every module, function, callback and option name the usage rules
  mention exists.

  Only inline code spans are read; fenced blocks hold example application
  modules this package cannot resolve. The test says nothing about whether a
  rule is correct, only that the code it names is real.
  """

  use ExUnit.Case, async: true

  alias AshMetrics.Config
  alias AshMetrics.Dsl

  @root "usage-rules.md"
  @directory "usage-rules"

  # A bare `fun/arity` reference is expected to be exported by one of these.
  @own [AshMetrics, AshMetrics.Test]

  # The bare references that are not this package's: Ash's `where:` conditions
  # and the expression functions used inside `expr/1`.
  @external %{
    {:ago, 2} => Ash.Query.Function.Ago,
    {:attribute_equals, 2} => Ash.Resource.Validation.Builtins,
    {:changing, 1} => Ash.Resource.Validation.Builtins,
    {:data_one_of, 2} => Ash.Resource.Validation.Builtins,
    {:expr, 1} => Ash.Expr
  }

  # Options of the changes `AshMetrics.increment_on_write/2`,
  # `AshMetrics.increment_on_change/2` and `AshMetrics.observe_elapsed/2`.
  @change_options [:attribute, :counter, :distribution, :from, :to]

  # Keys of a `tags` entry declaring a path into the written record.
  @tag_options [:path, :values]

  # Option names that belong to neither the DSL nor `AshMetrics.Config`:
  #
  # * `where` is Ash's own option on a `change` declaration.
  # * `metadata` is an option of `AshMetrics.increment/3` and
  #   `AshMetrics.observe/4`.
  # * `value` is an option of `AshMetrics.Test.assert_metric_emitted/2`.
  # * `resources` is an option of `use AshMetrics.Test`.
  @allowed_options [:metadata, :resources, :value, :where]

  @fence ~r/^```.*?^```/ms
  @span ~r/`([^`\n]+)`/
  @module ~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+\b/
  @remote ~r/\b([A-Z]\w*(?:\.[A-Z]\w*)*)\.([a-z_]\w*[?!]?)\/(\d+)/
  @local ~r/\A([a-z_]\w*[?!]?)\/(\d+)\z/
  @option ~r/\A([a-z][a-z0-9_]*):\z/
  @callback_ref ~r/\Ac:/

  test "the root file lists every topic file" do
    root = File.read!(@root)

    for file <- File.ls!(@directory) do
      assert root =~ "#{@directory}/#{file}",
             "#{@root} does not list #{@directory}/#{file}"
    end
  end

  test "the usage rules name only modules that exist" do
    for {file, span} <- spans(), module <- modules(span) do
      assert Code.ensure_loaded?(Module.concat([module])),
             "#{file} names #{module}, which does not exist"
    end
  end

  test "the usage rules name only functions and callbacks that exist" do
    for {file, span} <- spans(),
        [_reference, module, function, arity] <- Regex.scan(@remote, span) do
      assert_remote(file, span, module, String.to_atom(function), String.to_integer(arity))
    end
  end

  test "the usage rules name only local functions this package exports" do
    for {file, span} <- spans(),
        [_reference, function, arity] <- [Regex.run(@local, span)] do
      assert_local(file, String.to_atom(function), String.to_integer(arity))
    end
  end

  test "the usage rules name only options that exist" do
    known = known_options()

    for {file, span} <- spans(), [_reference, option] <- [Regex.run(@option, span)] do
      assert String.to_atom(option) in known,
             "#{file} names the option `#{option}:`, which is neither a DSL " <>
               "option, an `:ash_metrics` configuration key, an option of an " <>
               "action change, nor one this test allows explicitly"
    end
  end

  @spec modules(String.t()) :: [String.t()]
  defp modules(span) do
    @module
    |> Regex.scan(span)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.filter(&ours?/1)
  end

  @spec ours?(String.t()) :: boolean()
  defp ours?(module) do
    String.starts_with?(module, ["AshMetrics.", "Mix.Tasks.AshMetrics."])
  end

  @spec assert_remote(String.t(), String.t(), String.t(), atom(), arity()) :: true
  defp assert_remote(file, span, module, function, arity) do
    module = Module.concat([module])

    assert Code.ensure_loaded?(module),
           "#{file} names #{inspect(module)}, which does not exist"

    if Regex.match?(@callback_ref, span) do
      assert {function, arity} in module.behaviour_info(:callbacks),
             "#{file} names the callback #{inspect(module)}.#{function}/#{arity}, " <>
               "which that behaviour does not declare"
    else
      assert exported?(module, function, arity),
             "#{file} names #{inspect(module)}.#{function}/#{arity}, which is not exported"
    end
  end

  @spec assert_local(String.t(), atom(), arity()) :: true
  defp assert_local(file, function, arity) do
    case Map.fetch(@external, {function, arity}) do
      {:ok, module} ->
        assert Code.ensure_loaded?(module),
               "#{file} names #{function}/#{arity}, whose module " <>
                 "#{inspect(module)} does not exist"

      :error ->
        assert Enum.any?(@own, &exported?(&1, function, arity)),
               "#{file} names #{function}/#{arity}, which none of " <>
                 "#{inspect(@own)} exports"
    end
  end

  @spec exported?(module(), atom(), arity()) :: boolean()
  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, function, arity) or
         macro_exported?(module, function, arity))
  end

  @spec spans() :: [{String.t(), String.t()}]
  defp spans do
    Enum.flat_map(files(), fn file ->
      file
      |> File.read!()
      |> String.replace(@fence, "")
      |> scan_spans()
      |> Enum.map(&{file, &1})
    end)
  end

  @spec scan_spans(String.t()) :: [String.t()]
  defp scan_spans(text) do
    @span
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  @spec files() :: [String.t()]
  defp files do
    topics = @directory |> File.ls!() |> Enum.map(&Path.join(@directory, &1))

    [@root | topics]
  end

  @spec known_options() :: [atom()]
  defp known_options do
    section = Dsl.metrics()
    entities = Enum.flat_map(section.entities, &Keyword.keys(&1.schema))

    Enum.uniq(
      Keyword.keys(section.schema) ++
        entities ++ config_keys() ++ @change_options ++ @tag_options ++ @allowed_options
    )
  end

  # `AshMetrics.Config` reads one key per zero-arity function, named after it
  # without the trailing `!` or `?`.
  @spec config_keys() :: [atom()]
  defp config_keys do
    for {name, 0} <- Config.__info__(:functions) do
      name
      |> to_string()
      |> String.trim_trailing("!")
      |> String.trim_trailing("?")
      |> String.to_atom()
    end
  end
end
