defmodule Handmedown.Schedule.ScorerTest do
  use ExUnit.Case, async: true

  alias Handmedown.Schedule.Scorer

  defp device(overrides \\ %{}) do
    Map.merge(%{id: "n-1", cores: 4, battery: 80, thermal: "nominal", running: 0}, overrides)
  end

  test "a healthy idle device is eligible" do
    assert Scorer.eligible?(device())
  end

  test "a hot device is never chosen" do
    refute Scorer.eligible?(device(%{thermal: "hot"}))
    assert Scorer.best([device(%{thermal: "hot"})], %{}) == nil
  end

  test "a drained device is never chosen" do
    refute Scorer.eligible?(device(%{battery: 14}))
    assert Scorer.eligible?(device(%{battery: 15}))
  end

  test "a desktop that reports no battery is eligible" do
    # -1 means "no reading", not "empty". Treating it as empty would keep every desktop idle.
    assert Scorer.eligible?(device(%{battery: -1}))
  end

  test "a device at its core count is full" do
    refute Scorer.eligible?(device(%{cores: 2, running: 2}))
    assert Scorer.eligible?(device(%{cores: 2, running: 1}))
  end

  test "a shard out of attempts is not handed out again" do
    refute Scorer.eligible?(device(), %{"attempts" => 3})
    assert Scorer.eligible?(device(), %{"attempts" => 2})
  end

  test "the least loaded device wins" do
    idle = device(%{id: "n-idle", cores: 4, running: 0})
    busy = device(%{id: "n-busy", cores: 4, running: 3})

    assert Scorer.best([busy, idle], %{}).id == "n-idle"
  end

  test "core count breaks a tie between equally idle devices" do
    small = device(%{id: "n-small", cores: 2, running: 0})
    big = device(%{id: "n-big", cores: 8, running: 0})

    # 1/8 beats 1/2: the big device can absorb more without slowing down.
    assert Scorer.best([small, big], %{}).id == "n-big"
  end

  test "ranking is deterministic when scores tie" do
    a = device(%{id: "n-b", cores: 4, running: 0})
    b = device(%{id: "n-a", cores: 4, running: 0})

    assert Enum.map(Scorer.rank([a, b], %{}), & &1.node.id) == ["n-a", "n-b"]
  end

  test "no eligible device means no placement" do
    assert Scorer.best([], %{}) == nil
    assert Scorer.best([device(%{thermal: "hot"})], %{}) == nil
  end
end
