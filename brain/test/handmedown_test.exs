defmodule HandmedownTest do
  use ExUnit.Case, async: true

  test "the fleet registry is supervised at boot" do
    # Small, but it is the contract the rest of the brain relies on: if this is not registered, every
    # per-device process lookup fails later in a confusing way instead of failing at startup.
    assert is_pid(Process.whereis(Handmedown.Fleet.Registry))
  end

  test "the supervisor is running under the application" do
    assert is_pid(Process.whereis(Handmedown.Supervisor))
  end
end
