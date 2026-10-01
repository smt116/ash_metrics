defmodule AshMetrics.AssertionsSharedTest do
  # Receives every emission, so it cannot run alongside other tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Invoice], shared: true

  alias AshMetrics.Test.Invoice

  test "receives an emission from a process the test does not own" do
    {pid, ref} = spawn_monitor(fn -> AshMetrics.increment(Invoice, :capture) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert_metric_emitted("test.mailings.invoice.capture")
  end

  test "rejects an unknown option" do
    assert_raise ArgumentError, fn ->
      Code.compile_string("""
      defmodule AshMetrics.AssertionsSharedTest.Typo do
        use AshMetrics.Test, sahred: true
      end
      """)
    end
  end
end
