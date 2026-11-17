defmodule Handmedown.Application do
  @moduledoc """
  Supervision root of the brain.

  Nothing here talks to a device yet. What is already load-bearing is the shape: every piece of
  per-device and per-shard state will be a supervised process registered in `Handmedown.Fleet.Registry`,
  so a crashed shard takes nothing else with it. That is the whole reason this half is Elixir.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Handmedown.Fleet.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Handmedown.Supervisor)
  end
end
