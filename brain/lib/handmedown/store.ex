defmodule Handmedown.Store do
  @moduledoc """
  Durable job and shard state.

  Deliberately not a database. The whole state is a map that is rewritten to one JSON file with an
  atomic rename, which gives three things a SQLite adapter would cost more for:

    * no NIF, no C compiler, no build step on the machine that runs the brain;
    * no repair semantics to reason about after a `kill -9` - the file is either the old snapshot or
      the new one, never a half-written one;
    * a bug report can include the state file and a human can read it.

  Nodes are *not* persisted. A device that is offline is not part of the fleet, and re-learns its
  identity from the hello frame when it comes back. Persisting liveness is how control planes end up
  scheduling onto machines that are switched off.
  """

  use GenServer
  require Logger
  @flush_ms 50

  # --- client ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Creates a job and its shards. Returns the job map."
  def create_job(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:create_job, attrs})

  @doc "All jobs, newest first."
  def jobs, do: GenServer.call(__MODULE__, :jobs)

  @doc "One job with its shards."
  def job(id), do: GenServer.call(__MODULE__, {:job, id})

  @doc "Every shard of every job."
  def shards, do: GenServer.call(__MODULE__, :shards)

  @doc "Updates a shard by id with the given function. Returns the new shard or :error."
  def update_shard(id, fun) when is_function(fun, 1),
    do: GenServer.call(__MODULE__, {:update_shard, id, fun})

  @doc "Updates a job by id with the given function. Returns the new job or :error."
  def update_job(id, fun) when is_function(fun, 1),
    do: GenServer.call(__MODULE__, {:update_job, id, fun})

  @doc "Forces a flush. Used by tests and before a graceful shutdown."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "The whole state, for the dashboard and for tests."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir) || Application.get_env(:handmedown, :data_dir)

    state = %{
      path: path_for(dir),
      jobs: %{},
      shards: %{},
      dirty: false
    }

    state = load(state)
    if state.dirty, do: flush_now(state)

    {:ok, %{state | dirty: false}}
  end

  @impl true
  def handle_call({:create_job, attrs}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    id = new_id()

    job = %{
      "id" => id,
      "cmd" => Map.fetch!(attrs, "cmd"),
      "inputs" => Map.fetch!(attrs, "inputs"),
      "shard_count" => Map.fetch!(attrs, "shards"),
      "outdir" => Map.get(attrs, "outdir", "out"),
      "created_at" => now,
      "status" => "queued"
    }

    shards =
      for {slice, index} <- Enum.with_index(slice_inputs(job["inputs"], job["shard_count"])) do
        %{
          "id" => "#{id}-#{index}",
          "job_id" => id,
          "index" => index,
          "total" => job["shard_count"],
          "inputs" => slice,
          "status" => "queued",
          "attempts" => 0,
          "node_id" => nil,
          "lease_until" => nil,
          "digest" => nil,
          "done" => 0
        }
      end

    state =
      state
      |> put_job(job)
      |> put_shards(shards)
      |> touch()

    {:reply, Map.put(job, "shards", shards), state}
  end

  def handle_call(:jobs, _from, state) do
    jobs = state.jobs |> Map.values() |> Enum.sort_by(& &1["created_at"], :desc)
    {:reply, jobs, state}
  end

  def handle_call({:job, id}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        shards = state.shards |> Map.values() |> Enum.filter(&(&1["job_id"] == id))
        {:reply, {:ok, Map.put(job, "shards", Enum.sort_by(shards, & &1["index"]))}, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:shards, _from, state) do
    {:reply, state.shards |> Map.values() |> Enum.sort_by(& &1["id"]), state}
  end

  def handle_call({:update_shard, id, fun}, _from, state) do
    case Map.fetch(state.shards, id) do
      {:ok, shard} ->
        updated = fun.(shard)
        state = put_shard(state, updated) |> touch()
        {:reply, {:ok, updated}, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:update_job, id, fun}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        updated = fun.(job)
        state = put_job(state, updated) |> touch()
        {:reply, {:ok, updated}, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, %{jobs: Map.values(state.jobs), shards: Map.values(state.shards)}, state}
  end

  def handle_call(:flush, _from, state) do
    flush_now(state)
    {:reply, :ok, %{state | dirty: false}}
  end

  @impl true
  def handle_info(:flush, state) do
    if state.dirty do
      flush_now(state)
      {:noreply, %{state | dirty: false}}
    else
      {:noreply, state}
    end
  end

  # --- persistence ----------------------------------------------------------

  defp touch(state) do
    # Debounced: a shard moving from queued to running to done should not cost three fsyncs, but it
    # must not wait for a timer that a crash could cancel either. 50 ms is both.
    if not state.dirty, do: Process.send_after(self(), :flush, @flush_ms)
    %{state | dirty: true}
  end

  defp flush_now(%{path: nil}), do: :ok

  defp flush_now(state) do
    payload = %{
      "version" => 1,
      "jobs" => Map.values(state.jobs),
      "shards" => Map.values(state.shards)
    }

    # Write to a sibling file and rename over the real one: on every filesystem we support, the
    # rename is atomic, so a crash leaves either the previous snapshot or this one.
    temp = state.path <> ".tmp"
    File.mkdir_p!(Path.dirname(state.path))
    File.write!(temp, Jason.encode!(payload))
    File.rename!(temp, state.path)
    :ok
  rescue
    error ->
      Logger.error("store: could not write #{state.path}: #{inspect(error)}")
      :ok
  end

  defp load(%{path: nil} = state), do: state

  defp load(state) do
    case File.read(state.path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, payload} ->
            %{
              state
              | jobs: Map.new(payload["jobs"] || [], &{&1["id"], &1}),
                shards: Map.new(payload["shards"] || [], &{&1["id"], &1})
            }

          {:error, _} ->
            Logger.warning("store: #{state.path} is not valid JSON; starting empty")
            state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        Logger.warning("store: cannot read #{state.path}: #{inspect(reason)}")
        state
    end
  end

  defp path_for(nil), do: nil
  defp path_for(dir), do: Path.join(dir, "state.json")

  defp put_job(state, job), do: %{state | jobs: Map.put(state.jobs, job["id"], job)}

  defp put_shard(state, shard), do: %{state | shards: Map.put(state.shards, shard["id"], shard)}

  defp put_shards(state, shards), do: Enum.reduce(shards, state, &put_shard(&2, &1))

  # Contiguous slices, matching the agent's own `--shard i/n` split, so a shard means the same thing
  # on both sides of the wire.
  defp slice_inputs(inputs, count) do
    inputs = Enum.sort(inputs)
    size = div(Enum.count(inputs) + count - 1, count)

    Enum.map(0..(count - 1), fn index ->
      inputs |> Enum.drop(index * size) |> Enum.take(size)
    end)
  end

  defp new_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
