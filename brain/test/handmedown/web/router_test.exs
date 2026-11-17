defmodule Handmedown.Web.RouterTest do
  @moduledoc """
  Route-level tests.

  These exist because the dashboard root shipped broken twice in this branch and every other gate stayed
  green: `conn.query_params` was read before it was fetched, so `GET /` raised while `/?live=0` worked,
  and the screenshot script was the only thing that noticed. A route returning 500 is exactly the kind
  of failure a unit test on the renderer cannot see, because the renderer was fine.

  The router is driven directly rather than over a socket: `Plug.Conn` is the seam, and it needs no
  port, no browser and no waiting.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias Handmedown.Web.Router

  defp get(path) do
    conn(:get, path) |> Router.call([])
  end

  defp post(path, body) do
    conn(:post, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call([])
  end

  describe "GET /" do
    test "renders the dashboard for a plain request" do
      response = get("/")

      assert response.status == 200
      assert response.resp_body =~ "handmedown"
      assert response.resp_body =~ "devices"
    end

    test "renders with a query string present" do
      assert get("/?live=0").status == 200
    end

    test "the live variant keeps the event stream, the snapshot variant drops it" do
      assert get("/").resp_body =~ "EventSource"
      refute get("/?live=0").resp_body =~ "EventSource"
    end
  end

  describe "GET /api/state" do
    test "returns the fleet as JSON" do
      response = get("/api/state")

      assert response.status == 200
      assert {:ok, payload} = Jason.decode(response.resp_body)

      # The dashboard addresses this by string key; atom keys once made every fleet look empty.
      assert Map.has_key?(payload, "nodes")
      assert Map.has_key?(payload, "state")
      assert Map.has_key?(payload["state"], "jobs")
      assert Map.has_key?(payload["state"], "shards")
    end
  end

  describe "POST /api/jobs" do
    test "rejects a malformed body without crashing the router" do
      response = post("/api/jobs", "{not json")

      assert response.status == 400
      assert response.resp_body =~ "JSON"
    end

    test "rejects a body that is JSON but not a job" do
      response = post("/api/jobs", ~s({"cmd":[]}))

      assert response.status == 400
      assert response.resp_body =~ "cmd"
    end

    test "accepts a valid job" do
      body = Jason.encode!(%{"cmd" => ["echo", "hi"], "inputs" => ["a"], "shards" => 1})
      response = post("/api/jobs", body)

      assert response.status == 201
      assert {:ok, payload} = Jason.decode(response.resp_body)
      assert payload["shards"] == 1
      assert is_binary(payload["id"])
    end
  end

  test "an unknown path is a 404, not a crash" do
    assert get("/nope").status == 404
  end

  test "health answers without touching the fleet" do
    response = get("/health")
    assert response.status == 200
    assert response.resp_body == "ok"
  end
end
