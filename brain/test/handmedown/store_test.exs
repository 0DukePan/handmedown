defmodule Handmedown.StoreTest do
  use ExUnit.Case, async: false

  alias Handmedown.Store

  test "shards cover every input exactly once" do
    job =
      Store.create_job(%{
        "cmd" => ["tool"],
        "inputs" => Enum.map(1..10, &"in-#{&1}"),
        "shards" => 3
      })

    inputs = job["shards"] |> Enum.flat_map(& &1["inputs"])
    assert length(inputs) == 10
    assert Enum.uniq(inputs) == Enum.sort(inputs)

    # Shard indexes are 0-based and total is the job's shard count, matching the agent's --shard i/n.
    assert Enum.map(job["shards"], & &1["index"]) == [0, 1, 2]
    assert Enum.all?(job["shards"], &(&1["total"] == 3))
    assert Enum.all?(job["shards"], &(&1["status"] == "queued"))
    assert Enum.all?(job["shards"], &(&1["attempts"] == 0))
  end

  test "a job with fewer inputs than shards still produces empty shards" do
    job = Store.create_job(%{"cmd" => ["tool"], "inputs" => ["only"], "shards" => 3})
    assert length(job["shards"]) == 3
    assert Enum.map(job["shards"], & &1["inputs"]) == [["only"], [], []]
  end

  test "update_shard changes one shard and leaves the rest alone" do
    job = Store.create_job(%{"cmd" => ["tool"], "inputs" => ["a", "b"], "shards" => 2})
    [first, second] = job["shards"]

    {:ok, updated} = Store.update_shard(first["id"], &Map.put(&1, "status", "done"))
    assert updated["status"] == "done"

    {:ok, fetched} = Store.job(job["id"])
    statuses = Map.new(fetched["shards"], &{&1["id"], &1["status"]})
    assert statuses[first["id"]] == "done"
    assert statuses[second["id"]] == "queued"
  end

  test "state survives a store restart" do
    dir = Path.join(System.tmp_dir!(), "handmedown-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:handmedown, :data_dir)
    Application.put_env(:handmedown, :data_dir, dir)

    supervisor = Handmedown.Supervisor

    try do
      # Restart the store so it opens the directory above, then write a job.
      :ok = Supervisor.terminate_child(supervisor, Store)
      {:ok, _pid} = Supervisor.restart_child(supervisor, Store)

      job = Store.create_job(%{"cmd" => ["tool"], "inputs" => ["a"], "shards" => 1})
      # The write is debounced; force it rather than sleeping for the timer.
      :ok = Store.flush()
      assert File.exists?(Path.join(dir, "state.json"))

      # Kill and reopen: this is the "brain restarted" case the demo depends on.
      :ok = Supervisor.terminate_child(supervisor, Store)
      {:ok, _pid} = Supervisor.restart_child(supervisor, Store)

      {:ok, reloaded} = Store.job(job["id"])
      assert reloaded["cmd"] == ["tool"]
      assert [%{"status" => "queued"}] = reloaded["shards"]
    after
      :ok = Supervisor.terminate_child(supervisor, Store)
      Application.put_env(:handmedown, :data_dir, previous)
      {:ok, _pid} = Supervisor.restart_child(supervisor, Store)
      File.rm_rf(dir)
    end
  end

  test "a corrupt state file does not prevent boot" do
    dir = Path.join(System.tmp_dir!(), "handmedown-corrupt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "state.json"), "{ this is not json")

    previous = Application.get_env(:handmedown, :data_dir)
    Application.put_env(:handmedown, :data_dir, dir)
    supervisor = Handmedown.Supervisor

    try do
      :ok = Supervisor.terminate_child(supervisor, Store)
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, Store)
      # Empty, not crashed: losing the index is recoverable, refusing to boot is not.
      assert Store.jobs() == []
    after
      :ok = Supervisor.terminate_child(supervisor, Store)
      Application.put_env(:handmedown, :data_dir, previous)
      {:ok, _pid} = Supervisor.restart_child(supervisor, Store)
      File.rm_rf(dir)
    end
  end
end
