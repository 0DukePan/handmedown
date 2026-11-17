defmodule Handmedown.Broadcast do
  @moduledoc """
  Fan-out to the dashboard's event streams.

  A registry small enough to read in one sitting, instead of pulling in a PubSub library: SSE
  subscribers register here, and every state change is pushed to all of them. If a subscriber has
  died its pid is dropped on the next send, which is the entire lifecycle story.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Subscribes the calling process to state pushes."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "Pushes the given payload to every subscriber."
  def push(payload), do: GenServer.cast(__MODULE__, {:push, payload})

  @impl true
  def init(:ok), do: {:ok, %{subscribers: MapSet.new()}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:push, payload}, state) do
    alive =
      Enum.reduce(state.subscribers, MapSet.new(), fn pid, acc ->
        case safe_send(pid, {:state, payload}) do
          :ok -> MapSet.put(acc, pid)
          :dead -> acc
        end
      end)

    {:noreply, %{state | subscribers: alive}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp safe_send(pid, message) do
    send(pid, message)
    :ok
  catch
    :error, _reason -> :dead
  end
end
