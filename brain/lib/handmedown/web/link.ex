defmodule Handmedown.Web.Link do
  @moduledoc """
  One process per connected device, and that process owns the socket.

  Keeping the connection and the device's scheduling identity in the same process means "the device
  went away" is just `:DOWN` - there is no second registry to fall out of sync, and no cleanup path
  that can forget to run.

  The first frame must be `hello` with the right token. Nothing before that is trusted: an
  unauthenticated socket may not report facts, receive a lease, or learn anything about the fleet.
  """

  @behaviour WebSock

  alias Handmedown.{Schedule, Store}

  @protocol "v1"
  @beat_ms 5_000

  @impl true
  def init(opts) do
    {:ok, %{token: Keyword.fetch!(opts, :token), node_id: nil}}
  end

  @impl true
  def handle_in({frame, [opcode: :text]}, state), do: decode(frame, state)

  def handle_in({_frame, [opcode: :binary]}, state) do
    # v1 is JSON only. Accepting binary here would mean inventing a second format with no reader.
    {:stop, :protocol_error, {1003, "text frames only"}, state}
  end

  @impl true
  def handle_info({:hand, :lease, shard}, state) do
    case lease_frame(shard) do
      {:ok, frame} -> {:push, {:text, frame}, state}
      {:error, reason} -> {:stop, {:lease_failed, reason}, {1011, "cannot build lease"}, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{node_id: nil}), do: :ok

  def terminate(_reason, %{node_id: node_id}) do
    Schedule.node_lost(node_id)
    :ok
  end

  # --- frames ---------------------------------------------------------------

  defp decode(frame, state) do
    case Jason.decode(frame) do
      {:ok, %{"v" => @protocol, "type" => type, "data" => data}} ->
        route(type, data, state)

      {:ok, %{"v" => other}} ->
        {:stop, :protocol_error, {1002, "protocol #{other}, this brain speaks #{@protocol}"}, state}

      {:ok, _} ->
        {:stop, :protocol_error, {1002, "every message needs v and type"}, state}

      {:error, _reason} ->
        {:stop, :protocol_error, {1003, "not JSON"}, state}
    end
  end

  defp route("hello", data, state), do: hello(data, state)

  defp route(type, _data, %{node_id: nil} = state) do
    # Order matters for security, not just tidiness: a device that has not authenticated must not be
    # able to move fleet state by sending beats or completions.
    {:stop, :unauthorized, {1008, "#{type} before hello"}, state}
  end

  defp route("beat", data, state) do
    Schedule.beat(state.node_id, data)
    {:ok, state}
  end

  defp route("ack", data, state) do
    Schedule.ack(state.node_id, data["shard_id"], data["resume_seq"] || 0)
    {:ok, state}
  end

  defp route("progress", data, state) do
    Schedule.progress(
      state.node_id,
      data["shard_id"],
      data["done"] || 0,
      data["total"] || 0,
      data["seq"] || 0
    )

    {:ok, state}
  end

  defp route("done", data, state) do
    Schedule.done(
      state.node_id,
      data["shard_id"],
      data["digest"],
      data["inputs_done"] || 0,
      data["duration_ms"] || 0
    )

    {:ok, state}
  end

  defp route("fail", data, state) do
    Schedule.fail(
      state.node_id,
      data["shard_id"],
      data["error"] || "unknown",
      data["exit_code"] || 1
    )

    {:ok, state}
  end

  defp route(type, _data, state) do
    {:stop, :protocol_error, {1003, "unknown message type #{type}"}, state}
  end

  defp hello(data, state) do
    if secure_compare(to_string(data["token"] || ""), state.token) do
      node_id = new_node_id()

      facts = %{
        "host" => data["host"] || "unknown",
        "os" => data["os"] || "unknown",
        "arch" => data["arch"] || "unknown",
        "cores" => data["cores"] || 1,
        "mem_mb" => data["mem_mb"] || 0,
        "disk_free_mb" => data["disk_free_mb"] || 0,
        "battery" => data["battery"] || -1,
        "thermal" => data["thermal"] || "unknown",
        "agent_version" => data["agent_version"] || "unknown"
      }

      :ok = Schedule.node_registered(node_id, self(), facts)

      welcome = %{
        "v" => @protocol,
        "type" => "welcome",
        "data" => %{
          "node_id" => node_id,
          "brain_version" => to_string(Application.spec(:handmedown, :vsn) || "dev"),
          "beat_ms" => @beat_ms
        }
      }

      {:push, {:text, Jason.encode!(welcome)}, %{state | node_id: node_id}}
    else
      {:stop, :unauthorized, {1008, "bad join token"}, state}
    end
  end

  defp lease_frame(shard) do
    with {:ok, job} <- Store.job(shard["job_id"]) do
      frame = %{
        "v" => @protocol,
        "type" => "lease",
        "data" => %{
          "shard_id" => shard["id"],
          "job_id" => shard["job_id"],
          "attempt" => shard["attempts"],
          "cmd" => job["cmd"],
          "env" => %{},
          "inputs" => shard["inputs"],
          "outdir" => job["outdir"],
          "index" => shard["index"],
          "total" => shard["total"],
          "ttl_ms" => Application.get_env(:handmedown, :lease_ms, 30_000)
        }
      }

      {:ok, Jason.encode!(frame)}
    else
      :error -> {:error, :unknown_job}
    end
  end

  # Constant-time comparison: the token is a secret, and `==` leaks its prefix through timing.
  defp secure_compare(left, right) do
    if byte_size(left) == byte_size(right) do
      Plug.Crypto.secure_compare(left, right)
    else
      false
    end
  end

  defp new_node_id do
    "n-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
