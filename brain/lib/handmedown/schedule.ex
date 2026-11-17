defmodule Handmedown.Schedule do
  @moduledoc """
  The only authority in the system: who holds which shard, and for how long.

  There is no consensus here, no leader election and no membership protocol, on purpose. Devices are
  not peers - they are unreliable clients - so the brain decides, devices comply, and every decision
  has an expiry. A device that stops talking does not need to be declared dead by a quorum; its lease
  simply runs out and the shard goes back in the queue.

  Time is wall-clock milliseconds, not monotonic, because lease deadlines are persisted and must still
  mean something after a restart. A device whose clock is wrong is unaffected: deadlines are computed
  here, and the agent never reasons about them.
  """

  use GenServer
  require Logger

  alias Handmedown.{Broadcast, Store}
  alias Handmedown.Schedule.Scorer

  # --- client ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "A device said hello. It becomes schedulable immediately."
  def node_registered(node_id, pid, facts),
    do: GenServer.call(__MODULE__, {:registered, node_id, pid, facts})

  @doc "A heartbeat: liveness, current load, and progress per running shard."
  def beat(node_id, payload), do: GenServer.cast(__MODULE__, {:beat, node_id, payload})

  def ack(node_id, shard_id, resume_seq),
    do: GenServer.cast(__MODULE__, {:ack, node_id, shard_id, resume_seq})

  def progress(node_id, shard_id, done, total, seq),
    do: GenServer.cast(__MODULE__, {:progress, node_id, shard_id, done, total, seq})

  def done(node_id, shard_id, digest, inputs_done, duration_ms),
    do: GenServer.call(__MODULE__, {:done, node_id, shard_id, digest, inputs_done, duration_ms})

  def fail(node_id, shard_id, error, exit_code),
    do: GenServer.call(__MODULE__, {:fail, node_id, shard_id, error, exit_code})

  @doc "Called by the websocket handler when a device disconnects."
  def node_lost(node_id), do: GenServer.cast(__MODULE__, {:lost, node_id})

  @doc "Connected devices, for the dashboard."
  def nodes, do: GenServer.call(__MODULE__, :nodes)

  @doc "Creates a job and its shards, then tries to place them immediately."
  def create_job(attrs) do
    job = Store.create_job(attrs)
    GenServer.call(__MODULE__, :dispatch)
    Broadcast.push(snapshot_now())
    job
  end

  @doc "The dashboard's whole view."
  def snapshot_now, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Place queued shards now. Tests call this instead of waiting for a timer."
  def dispatch_now, do: GenServer.call(__MODULE__, :dispatch)

  @doc "Expire leases now. Same reason as `dispatch_now/0`."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:handmedown, :max_attempts, 3)

    state = %{
      nodes: %{},
      lease_ms: Keyword.get(opts, :lease_ms) || Application.get_env(:handmedown, :lease_ms, 30_000),
      sweep_ms: Keyword.get(opts, :sweep_ms) || Application.get_env(:handmedown, :sweep_ms, 5_000),
      max_attempts: Keyword.get(opts, :max_attempts) || config,
      dispatching: false
    }

    schedule_sweep(state.sweep_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:registered, node_id, pid, facts}, _from, state) do
    ref = Process.monitor(pid)

    node = %{
      id: node_id,
      pid: pid,
      ref: ref,
      facts: facts,
      cores: Map.get(facts, "cores", 1),
      arch: Map.get(facts, "arch", "unknown"),
      host: Map.get(facts, "host", node_id),
      battery: Map.get(facts, "battery", -1),
      thermal: Map.get(facts, "thermal", "unknown"),
      load: 0.0,
      running: MapSet.new(),
      beat_at: now_ms()
    }

    state = put_in(state.nodes[node_id], node)
    {:reply, :ok, dispatch(state)}
  end

  def handle_call(:nodes, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.map(fn node ->
        %{
          id: node.id,
          host: node.host,
          arch: node.arch,
          cores: node.cores,
          battery: node.battery,
          thermal: node.thermal,
          load: node.load,
          running: MapSet.size(node.running),
          shards: MapSet.to_list(node.running),
          beat_at: node.beat_at
        }
      end)

    {:reply, nodes, state}
  end

  def handle_call(:dispatch, _from, state), do: {:reply, :ok, dispatch(state)}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:sweep, _from, state) do
    state = expire_leases(state)
    {:reply, :ok, dispatch(state)}
  end

  def handle_call({:done, node_id, shard_id, digest, inputs_done, duration_ms}, _from, state) do
    state = release(state, node_id, shard_id)

    {:ok, shard} =
      Store.update_shard(shard_id, fn shard ->
        case shard["digest"] do
          # First completion: record it.
          nil ->
            shard
            |> Map.put("status", "done")
            |> Map.put("digest", digest)
            |> Map.put("done", inputs_done)
            |> Map.put("duration_ms", duration_ms)
            |> Map.put("node_id", node_id)
            |> Map.put("lease_until", nil)

          # Same shard completed again with the same output: a harmless duplicate (the classic case is
          # an agent whose completion frame was lost), so accept it and move on.
          ^digest ->
            Map.put(shard, "status", "done")

          # Two devices produced different bytes for one shard. Never pick a winner: that means the
          # command is not deterministic, and hiding it would hide the bug the user needs to see.
          other ->
            Logger.warning(
              "shard #{shard_id} completed twice with different digests: #{digest} vs #{other}"
            )

            shard
            |> Map.put("status", "conflicted")
            |> Map.put("conflict_digest", digest)
        end
      end)

    state = state |> refresh_job(shard["job_id"]) |> dispatch()
    broadcast(state)
    {:reply, {:ok, shard}, state}
  end

  def handle_call({:fail, node_id, shard_id, error, exit_code}, _from, state) do
    state = release(state, node_id, shard_id)

    {:ok, shard} =
      Store.update_shard(shard_id, fn shard ->
        # A failure with attempts left is not a failure, it is a retry. Only when the budget is spent
        # does the shard become failed.
        status = if shard["attempts"] >= state.max_attempts, do: "failed", else: "queued"

        shard
        |> Map.put("status", status)
        |> Map.put("error", error)
        |> Map.put("exit_code", exit_code)
        |> Map.put("node_id", nil)
        |> Map.put("lease_until", nil)
      end)

    state = state |> refresh_job(shard["job_id"]) |> dispatch()
    broadcast(state)
    {:reply, {:ok, shard}, state}
  end

  @impl true
  def handle_cast({:beat, node_id, payload}, state) do
    case Map.fetch(state.nodes, node_id) do
      {:ok, node} ->
        node = %{
          node
          | beat_at: now_ms(),
            load: Map.get(payload, "load", 0.0),
            battery: Map.get(payload, "battery", node.battery),
            thermal: Map.get(payload, "thermal", node.thermal)
        }

        state = put_in(state.nodes[node_id], node)
        {:noreply, state}

      :error ->
        # Beats from a device we do not know are what a restarted brain sees first. Ignore them; the
        # device reconnects and re-hellos, which is the only path that re-establishes identity.
        {:noreply, state}
    end
  end

  def handle_cast({:ack, _node_id, _shard_id, _resume_seq}, state), do: {:noreply, state}

  def handle_cast({:progress, _node_id, shard_id, done, total, _seq}, state) do
    _ =
      Store.update_shard(shard_id, fn shard ->
        Map.merge(shard, %{"done" => done, "total_inputs" => total})
      end)

    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:lost, node_id}, state) do
    {:noreply, drop_node(state, node_id)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.nodes, fn {_id, node} -> node.pid == pid end) do
      {node_id, _node} -> {:noreply, drop_node(state, node_id)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_ms)
    {:noreply, state |> expire_leases() |> dispatch()}
  end

  # --- leasing --------------------------------------------------------------

  defp dispatch(%{dispatching: true} = state), do: state

  defp dispatch(state) do
    state = %{state | dispatching: true}

    queued =
      all_shards()
      |> Enum.filter(&(&1["status"] == "queued"))
      |> Enum.sort_by(& &1["index"])

    {state, placed} =
      Enum.reduce(queued, {state, 0}, fn shard, {acc, count} ->
        # Scorer works on its own slim view of a node, and the socket pid lives only in this process's
        # state, so a score is turned back into an id before anything is placed.
        case Scorer.best(node_list(acc), shard) do
          nil -> {acc, count}
          ranked -> {place(acc, ranked.id, shard), count + 1}
        end
      end)

    state = %{state | dispatching: false}
    if placed > 0, do: broadcast(state)
    state
  end

  defp node_list(state) do
    state.nodes
    |> Map.values()
    |> Enum.map(fn node ->
      %{
        id: node.id,
        cores: node.cores,
        battery: node.battery,
        thermal: node.thermal,
        running: MapSet.size(node.running)
      }
    end)
  end

  defp place(state, node_id, shard) do
    node = Map.fetch!(state.nodes, node_id)
    lease_until = now_ms() + state.lease_ms

    {:ok, leased} =
      Store.update_shard(shard["id"], fn shard ->
        shard
        |> Map.put("status", "leased")
        |> Map.put("node_id", node.id)
        |> Map.put("lease_until", lease_until)
        |> Map.put("attempts", shard["attempts"] + 1)
        |> Map.put("error", nil)
      end)

    send(node.pid, {:hand, :lease, leased})

    # A leased shard means the job is no longer queued, so the job's status has to move at placement
    # time - otherwise the dashboard calls a running job "queued" until the first shard finishes.
    refresh_job(state, leased["job_id"])

    update_in(state.nodes[node_id], fn current ->
      %{current | running: MapSet.put(current.running, shard["id"])}
    end)
  end

  # A lease whose deadline has passed goes back in the queue, unless it has spent its attempts.
  defp expire_leases(state) do
    now = now_ms()

    expired =
      all_shards()
      |> Enum.filter(
        &(&1["status"] == "leased" and is_integer(&1["lease_until"]) and &1["lease_until"] <= now)
      )

    Enum.reduce(expired, state, fn shard, acc ->
      status = if shard["attempts"] >= state.max_attempts, do: "failed", else: "queued"

      {:ok, updated} =
        Store.update_shard(shard["id"], fn shard ->
          shard
          |> Map.put("status", status)
          |> Map.put("node_id", nil)
          |> Map.put("lease_until", nil)
          |> Map.put(
            "error",
            if(status == "failed",
              do: "lease expired #{shard["attempts"]} times",
              else: "lease expired"
            )
          )
        end)

      acc
      |> release(shard["node_id"], shard["id"])
      |> refresh_job(updated["job_id"])
    end)
  end

  defp release(state, nil, _shard_id), do: state

  defp release(state, node_id, shard_id) do
    case Map.fetch(state.nodes, node_id) do
      {:ok, _node} ->
        update_in(state.nodes[node_id], fn current ->
          %{current | running: MapSet.delete(current.running, shard_id)}
        end)

      :error ->
        state
    end
  end

  defp drop_node(state, node_id) do
    case Map.pop(state.nodes, node_id) do
      {nil, _rest} ->
        state

      {node, rest} ->
        Enum.each(node.running, fn shard_id ->
          # The shard is not failed: the device is gone, not the command. It goes back to the queue
          # immediately so another device can pick it up without waiting for the lease to expire -
          # the agent's journal makes that safe even while the old device is still working.
          _ =
            Store.update_shard(shard_id, fn shard ->
              shard
              |> Map.put("status", "queued")
              |> Map.put("node_id", nil)
              |> Map.put("lease_until", nil)
            end)
        end)

        fresh = %{state | nodes: rest}
        fresh = dispatch(fresh)
        broadcast(fresh)
        fresh
    end
  end

  # --- jobs -----------------------------------------------------------------

  # A job is "done" only when every shard is; "conflicted" outranks "partial" because a digest
  # disagreement is a correctness signal, not a retry signal.
  defp refresh_job(state, job_id) do
    case fetch_job(job_id) do
      {:ok, job} ->
        shards = job["shards"]

        # "queued" means no shard has started. Anything leased or finished means the job is under way,
        # and calling that "queued" on the dashboard is a lie the user can see.
        status =
          cond do
            Enum.any?(shards, &(&1["status"] == "conflicted")) -> "conflicted"
            Enum.all?(shards, &(&1["status"] == "done")) -> "done"
            Enum.any?(shards, &(&1["status"] == "failed")) -> "partial"
            Enum.all?(shards, &(&1["status"] == "queued")) -> "queued"
            true -> "running"
          end

        # Only the status is written back: the stored job has no "shards" key, and embedding one here
        # would make the snapshot grow on every refresh.
        _ = Store.update_job(job_id, &Map.put(&1, "status", status))
        state

      :error ->
        state
    end
  end

  defp broadcast(state) do
    Broadcast.push(snapshot(state))
  end

  @doc """
  The whole view the dashboard renders. Sent as one payload rather than diffs: at fleet sizes this is
  meant for, a consistent snapshot is cheaper to reason about than an event log with ordering rules.
  """
  def snapshot(state) do
    %{
      "nodes" =>
        state.nodes
        |> Map.values()
        |> Enum.map(fn node ->
          %{
            "id" => node.id,
            "host" => node.host,
            "arch" => node.arch,
            "cores" => node.cores,
            "battery" => node.battery,
            "thermal" => node.thermal,
            "running" => MapSet.size(node.running),
            "beat_at" => node.beat_at
          }
        end),
      "state" => store_snapshot(),
      "lease_ms" => state.lease_ms,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # --- resilience -----------------------------------------------------------

  # The store is a sibling under the same supervisor. If it is briefly unavailable (restarting, or a
  # test asserting a reload) a sweep must skip, not crash the brain: a scheduler that dies because its
  # index blinked is a control plane that cannot recover, which is the exact opposite of the promise.
  defp safe(fun, default) do
    try do
      fun.()
    catch
      :exit, _reason -> default
    end
  end

  defp all_shards, do: safe(fn -> Store.shards() end, [])
  defp fetch_job(id), do: safe(fn -> Store.job(id) end, :error)
  defp store_snapshot, do: safe(fn -> Store.snapshot() end, %{"jobs" => [], "shards" => []})
  defp schedule_sweep(ms), do: Process.send_after(self(), :sweep, ms)

  defp now_ms, do: System.system_time(:millisecond)
end
