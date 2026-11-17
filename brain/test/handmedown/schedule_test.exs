defmodule Handmedown.ScheduleTest do
  @moduledoc """
  The behavioural proofs for leases, retries and digest conflicts.

  These run against the real scheduler process with the test process registered as a device, so a
  "device" here receives exactly the message a real one would. Time is not faked: expiry is forced by
  moving a lease deadline into the past and calling `sweep_now/0`, which is both faster and more
  honest than sleeping for 30 seconds.
  """

  use ExUnit.Case, async: false

  alias Handmedown.{Schedule, Store}

  setup do
    # Fresh in-memory store and scheduler for each test: both are singletons, so state would otherwise
    # leak between them.
    sup = Handmedown.Supervisor
    :ok = Supervisor.terminate_child(sup, Store)
    {:ok, _} = Supervisor.restart_child(sup, Store)
    :ok = Supervisor.terminate_child(sup, Schedule)
    {:ok, _} = Supervisor.restart_child(sup, Schedule)
    :ok
  end

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        "host" => "pixel",
        "os" => "linux",
        "arch" => "arm64",
        "cores" => 4,
        "mem_mb" => 4096,
        "disk_free_mb" => 20_000,
        "battery" => 80,
        "thermal" => "nominal"
      },
      overrides
    )
  end

  defp register(node_id, facts \\ facts()) do
    :ok = Schedule.node_registered(node_id, self(), facts)
  end

  defp job(shards, inputs) do
    Schedule.create_job(%{
      "cmd" => ["tool", "--x"],
      "inputs" => inputs,
      "shards" => shards,
      "outdir" => "out"
    })
  end

  defp shard!(job_id, index \\ 0) do
    {:ok, job} = Store.job(job_id)
    Enum.at(job["shards"], index)
  end

  test "a device gets a shard as soon as one exists" do
    register("n-1")
    created = job(1, ["a", "b"])

    assert_receive {:hand, :lease, leased}, 1_000
    assert leased["job_id"] == created["id"]
    assert leased["status"] == "leased"
    assert leased["attempts"] == 1
    assert leased["inputs"] == ["a", "b"]
    assert leased["node_id"] == "n-1"
  end

  test "no lease without a device, and one as soon as one joins" do
    created = job(1, ["a"])
    refute_receive {:hand, :lease, _}, 100

    register("n-1")
    assert_receive {:hand, :lease, leased}, 1_000
    assert leased["job_id"] == created["id"]
  end

  test "an expired lease is requeued and handed out again" do
    register("n-1")
    created = job(1, ["a"])
    assert_receive {:hand, :lease, first}, 1_000
    assert first["attempts"] == 1

    # Move the deadline into the past instead of waiting 30 seconds.
    {:ok, _} =
      Store.update_shard(
        first["id"],
        &Map.put(&1, "lease_until", System.system_time(:millisecond) - 1)
      )

    :ok = Schedule.sweep_now()

    assert_receive {:hand, :lease, second}, 1_000
    assert second["id"] == first["id"]
    assert second["attempts"] == 2
    assert second["job_id"] == created["id"]
  end

  test "a shard held by a live device is not handed to a second one" do
    register("n-1")
    job(1, ["a"])
    assert_receive {:hand, :lease, %{"id" => shard_id}}, 1_000

    register("n-2")
    :ok = Schedule.dispatch_now()

    refute_receive {:hand, :lease, %{"id" => ^shard_id}}, 200
  end

  test "completion is recorded once and the shard is not handed out again" do
    register("n-1")
    created = job(1, ["a"])
    assert_receive {:hand, :lease, leased}, 1_000

    {:ok, shard} = Schedule.done("n-1", leased["id"], "sha256:aaaa", 1, 120)
    assert shard["status"] == "done"
    assert shard["digest"] == "sha256:aaaa"

    :ok = Schedule.dispatch_now()
    refute_receive {:hand, :lease, _}, 200

    {:ok, finished} = Store.job(created["id"])
    assert finished["status"] == "done"
  end

  test "the same digest arriving twice is accepted, not treated as a conflict" do
    register("n-1")
    job(1, ["a"])
    assert_receive {:hand, :lease, leased}, 1_000

    {:ok, first} = Schedule.done("n-1", leased["id"], "sha256:aaaa", 1, 120)
    {:ok, second} = Schedule.done("n-1", leased["id"], "sha256:aaaa", 1, 120)

    assert first["status"] == "done"
    assert second["status"] == "done"
  end

  test "two devices reporting different digests is a conflict, never a winner" do
    register("n-1")
    created = job(1, ["a"])
    assert_receive {:hand, :lease, leased}, 1_000

    {:ok, _} = Schedule.done("n-1", leased["id"], "sha256:aaaa", 1, 120)
    {:ok, conflicted} = Schedule.done("n-2", leased["id"], "sha256:bbbb", 1, 130)

    assert conflicted["status"] == "conflicted"
    assert conflicted["digest"] == "sha256:aaaa"
    assert conflicted["conflict_digest"] == "sha256:bbbb"

    {:ok, finished} = Store.job(created["id"])
    assert finished["status"] == "conflicted"
  end

  test "a failure retries until the attempt budget is spent, then fails" do
    register("n-1")
    created = job(1, ["a"])

    assert_receive {:hand, :lease, first}, 1_000
    {:ok, shard} = Schedule.fail("n-1", first["id"], "exited 3", 3)
    assert shard["status"] == "queued"
    assert shard["error"] == "exited 3"

    :ok = Schedule.dispatch_now()
    assert_receive {:hand, :lease, second}, 1_000
    assert second["attempts"] == 2
    {:ok, shard} = Schedule.fail("n-1", second["id"], "exited 3", 3)
    assert shard["status"] == "queued"

    :ok = Schedule.dispatch_now()
    assert_receive {:hand, :lease, third}, 1_000
    assert third["attempts"] == 3
    {:ok, shard} = Schedule.fail("n-1", third["id"], "exited 3", 3)
    assert shard["status"] == "failed"

    {:ok, finished} = Store.job(created["id"])
    assert finished["status"] == "partial"
  end

  test "a device that disappears gives its shards back immediately" do
    register("n-1")
    job(1, ["a"])
    assert_receive {:hand, :lease, leased}, 1_000

    # A second device is waiting when the first drops.
    register("n-2")
    Schedule.node_lost("n-1")

    assert_receive {:hand, :lease, releaded}, 1_000
    assert releaded["id"] == leased["id"]
    assert releaded["attempts"] == 2
  end

  test "a hot device is not given work even when it is the only one" do
    register("n-1", facts(%{"thermal" => "hot"}))
    created = job(1, ["a"])

    refute_receive {:hand, :lease, _}, 200
    assert shard!(created["id"])["status"] == "queued"
  end

  test "work spreads across devices rather than piling onto one" do
    register("n-1", facts(%{"cores" => 2}))
    register("n-2", facts(%{"cores" => 2}))
    job(2, ["a", "b"])

    assert_receive {:hand, :lease, first}, 1_000
    assert_receive {:hand, :lease, second}, 1_000

    assert first["node_id"] != second["node_id"]
  end

  # Found by the review: `refresh_job` was called but its result discarded at placement time, so a job
  # with a leased shard was reported as "queued" on the dashboard for its whole first shard. Nothing
  # failed, because nothing asserted the job's status while work was in flight.
  test "a job whose shard is leased is running, not queued" do
    register("n-1")
    created = job(1, ["a"])

    assert_receive {:hand, :lease, _leased}, 1_000

    {:ok, current} = Store.job(created["id"])
    assert current["status"] == "running"
  end

  test "a job becomes done when every shard reports done" do
    register("n-1")
    created = job(2, ["a", "b"])

    assert_receive {:hand, :lease, first}, 1_000
    assert_receive {:hand, :lease, second}, 1_000

    {:ok, _} = Schedule.done("n-1", first["id"], "sha256:1111", 1, 10)
    {:ok, _} = Schedule.done("n-1", second["id"], "sha256:2222", 1, 10)

    {:ok, finished} = Store.job(created["id"])
    assert finished["status"] == "done"
  end
end
