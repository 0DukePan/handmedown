defmodule Handmedown.Application do
  @moduledoc """
  Supervision root of the brain.

  Boot order matters and is expressed by the child list: the broadcast fan-out must exist before
  anything pushes to it, the store before the scheduler reads shards, and the HTTP server last so no
  request can arrive before there is state to serve.
  """

  use Application

  alias Handmedown.Store

  @impl true
  def start(_type, _args) do
    token = ensure_token()
    Application.put_env(:handmedown, :join_token, token)

    children =
      [
        {Registry, keys: :unique, name: Handmedown.Fleet.Registry},
        {Handmedown.Broadcast, []},
        {Handmedown.Store, []},
        {Handmedown.Schedule, []}
      ] ++ server_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Handmedown.Supervisor)
  end

  defp server_children do
    if Application.get_env(:handmedown, :start_server, true) do
      port = Application.get_env(:handmedown, :port, 4100)

      # Printed rather than logged: this is the one thing a user needs on first run, and it must
      # appear even when the log level is warning.
      IO.puts("""

      handmedown brain
        dashboard  http://localhost:#{port}
        join       hand join --brain http://<this-host>:#{port} --token #{Application.get_env(:handmedown, :join_token)}
        state      #{Application.get_env(:handmedown, :data_dir) || "(in memory)"}
      """)

      [{Bandit, plug: Handmedown.Web.Router, port: port}]
    else
      []
    end
  end

  # The join token: explicit override, else the one this brain used last time, else a new one. Using
  # the same token across restarts is what stops every device on the network having to re-join
  # because the brain bounced.
  defp ensure_token do
    env_token = Application.get_env(:handmedown, :token)
    dir = Application.get_env(:handmedown, :data_dir)

    cond do
      is_binary(env_token) and env_token != "" ->
        env_token

      is_nil(dir) ->
        "test-token"

      true ->
        path = Path.join(dir, "token")

        case File.read(path) do
          {:ok, saved} when saved != "" ->
            String.trim(saved)

          _ ->
            token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
            File.mkdir_p!(dir)
            File.write!(path, token)
            token
        end
    end
  end

  @doc "Graceful shutdown: flush state so a restart does not lose the last few seconds."
  @impl true
  def stop(_state) do
    if Process.whereis(Store), do: Store.flush()
    :ok
  end
end
