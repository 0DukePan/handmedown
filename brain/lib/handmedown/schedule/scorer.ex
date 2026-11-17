defmodule Handmedown.Schedule.Scorer do
  @moduledoc """
  Which device gets the next shard.

  A pure function over node maps and one shard, because this is the part of the scheduler that people
  argue about and it should be readable and testable in isolation. It is deliberately simple: filter
  the devices that must not take work, then rank what is left by how loaded it already is.

  The vetoes are the interesting half. A phone at 4% battery or a device reporting `hot` is not a slow
  device, it is a device that will vanish mid-shard, and the cheapest way to handle that is to not
  start.
  """

  @min_battery 15

  @doc """
  Nodes ranked best-first. Each node is a map with at least `:id`, `:cores`, `:battery`, `:thermal`
  and `:running` (how many shards it holds right now).
  """
  def rank(nodes, shard) do
    nodes
    |> Enum.filter(&eligible?/1)
    |> Enum.map(fn node -> %{node: node, score: score(node, shard)} end)
    |> Enum.sort_by(fn entry -> {entry.score, entry.node.id} end)
  end

  @doc "The single best node, or nil."
  def best(nodes, shard) do
    case rank(nodes, shard) do
      [%{node: node} | _] -> node
      [] -> nil
    end
  end

  @doc """
  Whether a node may take this shard at all.

  `shard` may be a map with `"attempts"`; when the attempt budget is spent the shard must not be
  handed out again - it is not a scheduling question any more.
  """
  def eligible?(node, shard \\ %{}) do
    thermal = Map.get(node, :thermal, "unknown")
    battery = Map.get(node, :battery, -1)
    cores = Map.get(node, :cores, 1) |> max(1)
    running = Map.get(node, :running, 0)
    attempts = shard |> Map.get("attempts", 0)
    max_attempts = Application.get_env(:handmedown, :max_attempts, 3)

    cond do
      thermal == "hot" -> false
      battery >= 0 and battery < @min_battery -> false
      running >= cores -> false
      attempts >= max_attempts -> false
      true -> true
    end
  end

  @doc """
  Lower is better. The `+1` is the shard being placed, so a busy device loses to an idle one before any
  other tie-breaker is reached.
  """
  def score(node, _shard) do
    cores = Map.get(node, :cores, 1) |> max(1)
    running = Map.get(node, :running, 0)
    (running + 1) / cores
  end
end
