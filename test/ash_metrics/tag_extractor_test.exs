defmodule AshMetrics.TagExtractorTest.Leaky do
  @moduledoc false
  # Returns more keys than it declares, which the helper is expected to drop.

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  def tag_keys, do: [:region]

  @impl AshMetrics.TagExtractor
  def extract(metadata) do
    %{region: Map.get(metadata, :region, "unknown"), actor_id: "c0ffee", tenant: "acme"}
  end
end

defmodule AshMetrics.TagExtractorTest do
  # Swaps the configured extractor, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.TagExtractor
  alias AshMetrics.TagExtractorTest.Leaky

  setup do
    original = Application.get_env(:ash_metrics, :tag_extractor)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, :tag_extractor)
        extractor -> Application.put_env(:ash_metrics, :tag_extractor, extractor)
      end
    end)

    :ok
  end

  describe "AshMetrics.TagExtractor.Default" do
    test "declares only the tenant key" do
      assert TagExtractor.Default.tag_keys() == [:tenant]
    end

    test "takes a string tenant" do
      assert TagExtractor.Default.extract(%{tenant: "acme"}) == %{tenant: "acme"}
    end

    test "takes an atom tenant" do
      assert TagExtractor.Default.extract(%{tenant: :acme}) == %{tenant: :acme}
    end

    test "takes an integer tenant" do
      assert TagExtractor.Default.extract(%{tenant: 42}) == %{tenant: 42}
    end

    test "drops a nil tenant" do
      assert TagExtractor.Default.extract(%{tenant: nil}) == %{}
    end

    test "drops a struct tenant rather than stringifying an identifier out of it" do
      assert TagExtractor.Default.extract(%{tenant: %URI{host: "acme.test"}}) == %{}
    end

    test "drops a map tenant" do
      assert TagExtractor.Default.extract(%{tenant: %{id: 1}}) == %{}
    end

    test "drops a list tenant" do
      assert TagExtractor.Default.extract(%{tenant: ["acme"]}) == %{}
    end

    test "drops a tuple tenant" do
      assert TagExtractor.Default.extract(%{tenant: {:org, 1}}) == %{}
    end

    test "returns no tags when there is no tenant key at all" do
      assert TagExtractor.Default.extract(%{}) == %{}
      assert TagExtractor.Default.extract(%{actor: :someone}) == %{}
    end
  end

  describe "extract/1" do
    test "dispatches to the configured extractor" do
      assert TagExtractor.extract(%{tenant: "acme"}) == %{tenant: "acme"}
    end

    test "keeps only the keys the extractor declares" do
      Application.put_env(:ash_metrics, :tag_extractor, Leaky)

      assert TagExtractor.extract(%{region: "eu", tenant: "acme"}) == %{region: "eu"}
    end
  end
end
