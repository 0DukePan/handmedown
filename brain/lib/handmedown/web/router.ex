defmodule Handmedown.Web.Router do
  @moduledoc """
  HTTP surface: the dashboard, its event stream, the agent socket, and a tiny job API.

  Plug.Router rather than a full framework because there are six routes and none of them need a
  session, a cookie, a template engine or an asset pipeline.
  """

  use Plug.Router

  alias Handmedown.{Broadcast, Schedule}
  alias Handmedown.Web.Dashboard

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, Dashboard.page(Schedule.snapshot_now(), join_url()))
  end

  # Server-sent events: one long response, one JSON-encoded HTML fragment per state change. The
  # browser never computes anything, which is why the dashboard has no tests of its own logic - there
  # is none on that side of the wire.
  get "/events" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    :ok = Broadcast.subscribe()
    stream(conn)
  end

  get "/ws" do
    conn =
      WebSockAdapter.upgrade(conn, Handmedown.Web.Link, [token: join_token()], timeout: 120_000)

    halt(conn)
  end

  post "/api/jobs" do
    {:ok, body, conn} = read_body(conn)

    case Jason.decode(body) do
      {:ok, payload} -> create_job(payload, conn)
      {:error, _} -> send_resp(conn, 400, ~s({"error":"body must be JSON"}))
    end
  end

  get "/api/state" do
    send_resp(conn, 200, Jason.encode!(Schedule.snapshot_now()))
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers --------------------------------------------------------------

  defp stream(conn) do
    receive do
      {:state, snapshot} ->
        case chunk(conn, sse(Dashboard.fragment(snapshot))) do
          {:ok, conn} -> stream(conn)
          {:error, _reason} -> conn
        end
    after
      # A comment frame keeps proxies and browsers from deciding the stream is dead.
      15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream(conn)
          {:error, _reason} -> conn
        end
    end
  end

  defp sse(html) do
    # JSON-encoding the fragment escapes newlines, so the whole payload stays on one `data:` line.
    "data: " <> Jason.encode!(html) <> "\n\n"
  end

  defp create_job(payload, conn) do
    cmd = payload["cmd"]
    inputs = payload["inputs"]
    shards = payload["shards"] || 1

    cond do
      not (is_list(cmd) and cmd != [] and Enum.all?(cmd, &is_binary/1)) ->
        send_resp(conn, 400, ~s({"error":"cmd must be a non-empty list of strings"}))

      not (is_list(inputs) and inputs != [] and Enum.all?(inputs, &is_binary/1)) ->
        send_resp(conn, 400, ~s({"error":"inputs must be a non-empty list of strings"}))

      not (is_integer(shards) and shards >= 1 and shards <= 64) ->
        send_resp(conn, 400, ~s({"error":"shards must be an integer from 1 to 64"}))

      true ->
        job =
          Schedule.create_job(%{
            "cmd" => cmd,
            "inputs" => inputs,
            "shards" => shards,
            "outdir" => payload["outdir"] || "out"
          })

        send_resp(conn, 201, Jason.encode!(%{"id" => job["id"], "shards" => shards}))
    end
  end

  defp join_token, do: Application.get_env(:handmedown, :join_token, "dev")

  defp join_url do
    port = Application.get_env(:handmedown, :port, 4100)
    "hand join --brain http://<this-host>:#{port} --token #{join_token()}"
  end
end
