defmodule Handmedown.Web.Dashboard do
  @moduledoc """
  The whole UI, as a function from a state snapshot to HTML.

  No LiveView, no JS build, no node_modules: the page is server-rendered, and a 6-line script replaces
  one element's contents whenever the server pushes a new render over SSE. The rendering logic stays
  on the server (where the data and the tests are), and the browser stays a dumb terminal.
  """

  @doc "The full page: shell, initial render, and the SSE client."
  def page(snapshot, join_url) do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>handmedown</title>
      <style>#{css()}</style>
    </head>
    <body>
      <header>
        <h1>handmedown</h1>
        <p class="join">join with <code>#{escape(join_url)}</code></p>
      </header>
      <main id="fleet">#{fragment(snapshot)}</main>
      <footer>leases expire after #{snapshot["lease_ms"] || 30_000} ms; a device that goes quiet loses its shard, not its work</footer>
      <script>
        const stream = new EventSource("/events");
        stream.onmessage = (event) => {
          document.getElementById("fleet").innerHTML = JSON.parse(event.data);
        };
      </script>
    </body>
    </html>
    """
  end

  @doc "The part that gets re-rendered: nodes, jobs, shards."
  def fragment(snapshot) do
    """
    #{nodes_section(snapshot["nodes"] || [])}
    #{jobs_section(snapshot["state"] || %{})}
    """
  end

  defp nodes_section([]) do
    """
    <section>
      <h2>devices</h2>
      <p class="empty">no devices yet. on another machine: <code>hand join</code></p>
    </section>
    """
  end

  defp nodes_section(nodes) do
    rows =
      nodes
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn node ->
        """
        <tr>
          <td><span class="dot on"></span>#{escape(node["host"])}</td>
          <td class="id">#{escape(node["id"])}</td>
          <td>#{escape(node["arch"])}</td>
          <td class="num">#{node["cores"]}</td>
          <td class="num">#{battery(node["battery"])}</td>
          <td>#{thermal(node["thermal"])}</td>
          <td class="num">#{node["running"]}</td>
        </tr>
        """
      end)

    """
    <section>
      <h2>devices <span class="count">#{length(nodes)}</span></h2>
      <table>
        <thead><tr><th>host</th><th>node</th><th>arch</th><th>cores</th><th>battery</th><th>thermal</th><th>shards</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </section>
    """
  end

  defp jobs_section(%{"jobs" => jobs, "shards" => shards}) when jobs != [] do
    jobs
    |> Enum.sort_by(& &1["created_at"], :desc)
    |> Enum.map(fn job ->
      job_shards = Enum.filter(shards, &(&1["job_id"] == job["id"]))
      done = Enum.count(job_shards, &(&1["status"] == "done"))

      rows =
        Enum.map(job_shards, fn shard ->
          """
          <tr>
            <td class="num">#{shard["index"] + 1}/#{shard["total"]}</td>
            <td>#{status(shard["status"])}</td>
            <td class="num">#{shard["done"]}/#{length(shard["inputs"])}</td>
            <td>#{progress_bar(shard)}</td>
            <td class="id">#{escape(shard["node_id"] || "-")}</td>
            <td class="id small">#{escape(short_digest(shard["digest"]))}</td>
            <td class="num">#{shard["attempts"]}</td>
          </tr>
          """
        end)

      """
      <section>
        <h2>#{escape(job["status"])} <span class="id">#{escape(job["id"])}</span>
          <span class="count">#{done}/#{length(job_shards)} shards</span></h2>
        <p class="cmd"><code>#{escape(Enum.join(job["cmd"], " "))}</code></p>
        <table>
          <thead><tr><th>shard</th><th>status</th><th>inputs</th><th>progress</th><th>device</th><th>digest</th><th>tries</th></tr></thead>
          <tbody>#{rows}</tbody>
        </table>
      </section>
      """
    end)
    |> Enum.join("\n")
  end

  defp jobs_section(_state) do
    """
    <section>
      <h2>jobs</h2>
      <p class="empty">no jobs yet. from any machine with the CLI:
        <code>hand submit --inputs '*.mov' -- ./transcode</code></p>
    </section>
    """
  end

  defp progress_bar(shard) do
    total = max(length(shard["inputs"]), 1)
    done = shard["done"] || 0
    percent = min(round(done / total * 100), 100)

    """
    <div class="bar"><span style="width:#{percent}%"></span></div>
    """
  end

  defp status("done"), do: ~s(<span class="ok">done</span>)
  defp status("running"), do: "running"
  defp status("leased"), do: ~s(<span class="live">leased</span>)
  defp status("queued"), do: ~s(<span class="muted">queued</span>)
  defp status("failed"), do: ~s(<span class="bad">failed</span>)
  defp status("conflicted"), do: ~s(<span class="bad">conflicted</span>)
  defp status(other), do: escape(other)

  defp battery(percent) when is_integer(percent) and percent >= 0, do: "#{percent}%"
  defp battery(_), do: "—"

  defp thermal("nominal"), do: "nominal"
  defp thermal("warm"), do: ~s(<span class="warn">warm</span>)
  defp thermal("hot"), do: ~s(<span class="bad">hot</span>)
  defp thermal(_), do: "—"

  defp short_digest(nil), do: "-"
  defp short_digest(digest) when byte_size(digest) > 19, do: String.slice(digest, 0, 19) <> "…"
  defp short_digest(digest), do: digest

  # Everything interpolated into HTML goes through here. Job commands and host names come from other
  # machines, which makes them exactly the kind of input that must never be trusted.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp css do
    """
    :root { --bg:#0f1115; --fg:#dcdfe4; --dim:#7d8590; --line:#242a33; --ok:#3fb950; --bad:#f85149; --live:#58a6ff; --warn:#d29922; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
    header { padding:24px 32px 0; display:flex; justify-content:space-between; align-items:baseline; gap:16px; flex-wrap:wrap; }
    h1 { margin:0; font-size:18px; letter-spacing:-0.02em; }
    h2 { font-size:13px; text-transform:uppercase; letter-spacing:0.08em; color:var(--dim); margin:0 0 12px; font-weight:600; }
    .join, footer { color:var(--dim); font-size:12px; }
    .join code { color:var(--fg); background:#171b22; padding:2px 6px; border-radius:4px; }
    main { padding:8px 32px 32px; }
    section { border-top:1px solid var(--line); padding:20px 0; }
    table { width:100%; border-collapse:collapse; }
    th { text-align:left; font-weight:600; color:var(--dim); font-size:11px; text-transform:uppercase; letter-spacing:0.06em; padding:0 12px 8px 0; }
    td { padding:6px 12px 6px 0; border-bottom:1px solid #1a1f27; vertical-align:middle; }
    .num, .id { font-variant-numeric:tabular-nums; }
    .id { color:var(--dim); }
    .small { font-size:11px; }
    .count { color:var(--dim); font-weight:400; text-transform:none; letter-spacing:0; }
    .dot { display:inline-block; width:7px; height:7px; border-radius:50%; background:var(--dim); margin-right:8px; }
    .dot.on { background:var(--ok); }
    .ok { color:var(--ok); } .bad { color:var(--bad); } .warn { color:var(--warn); }
    .live { color:var(--live); } .muted { color:var(--dim); }
    .empty { color:var(--dim); }
    .cmd code { color:var(--fg); }
    .bar { width:120px; height:6px; background:#1a1f27; border-radius:3px; overflow:hidden; }
    .bar span { display:block; height:100%; background:var(--live); }
    footer { padding:0 32px 32px; }
    """
  end
end
