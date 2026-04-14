defmodule Symphony.Server.Router do
  @moduledoc """
  Optional HTTP server providing the observability dashboard and JSON REST API.

  Endpoints (spec §13.7):
  - GET  /             — human-readable status (JSON for now; HTML dashboard is a future extension)
  - GET  /api/v1/state — full runtime snapshot
  - GET  /api/v1/:id   — per-issue debug details
  - POST /api/v1/refresh — trigger immediate poll cycle
  """

  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Routes
  # ---------------------------------------------------------------------------

  get "/" do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, dashboard_html())
  end

  get "/api/v1/state" do
    send_json(conn, 200, state_payload())
  end

  get "/api/v1/:issue_identifier/log" do
    identifier = conn.params["issue_identifier"]

    case Symphony.Orchestrator.snapshot() do
      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})

      {:ok, snapshot} ->
        log =
          cond do
            entry = Enum.find(snapshot.running, &(&1.issue_identifier == identifier)) ->
              entry[:event_log] || []

            entry = Enum.find(snapshot.completed, &(&1.identifier == identifier)) ->
              entry[:event_log] || []

            true ->
              nil
          end

        if is_nil(log) do
          send_json(conn, 404, %{error: %{code: "issue_not_found", message: "Issue not found: #{identifier}"}})
        else
          send_json(conn, 200, %{issue_identifier: identifier, events: log})
        end
    end
  end

  get "/api/v1/completed" do
    case Symphony.Orchestrator.snapshot() do
      {:ok, snapshot} -> send_json(conn, 200, %{completed: snapshot.completed})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/api/v1/:issue_identifier" do
    identifier = conn.params["issue_identifier"]

    case find_issue_in_snapshot(identifier) do
      nil ->
        send_json(conn, 404, %{error: %{code: "issue_not_found", message: "Issue not found: #{identifier}"}})

      details ->
        send_json(conn, 200, details)
    end
  end

  post "/api/v1/refresh" do
    Symphony.Orchestrator.trigger_refresh()
    now = DateTime.to_iso8601(DateTime.utc_now())

    send_json(conn, 202, %{
      queued: true,
      coalesced: false,
      requested_at: now,
      operations: ["poll", "reconcile"]
    })
  end

  match _ do
    method = conn.method

    if method in ["GET", "POST", "PUT", "DELETE", "PATCH"] do
      send_json(conn, 405, %{error: %{code: "method_not_allowed", message: "Method not allowed"}})
    else
      send_json(conn, 404, %{error: %{code: "not_found", message: "Not found"}})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp state_payload do
    case Symphony.Orchestrator.snapshot() do
      {:ok, snapshot} ->
        now = DateTime.to_iso8601(DateTime.utc_now())

        %{
          generated_at: now,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            completed: length(snapshot.completed)
          },
          running: snapshot.running,
          retrying: snapshot.retrying,
          completed: snapshot.completed,
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      {:error, reason} ->
        %{error: %{code: "snapshot_error", message: inspect(reason)}}
    end
  end

  defp find_issue_in_snapshot(identifier) do
    case Symphony.Orchestrator.snapshot() do
      {:error, _} ->
        nil

      {:ok, snapshot} ->
        running = Enum.find(snapshot.running, &(&1.issue_identifier == identifier))
        retrying = Enum.find(snapshot.retrying, &(&1.issue_identifier == identifier))
        completed = Map.get(snapshot.completed, identifier)

        cond do
          running ->
            %{
              issue_identifier: identifier,
              issue_id: running.issue_id,
              status: "running",
              running: running,
              retry: nil
            }

          retrying ->
            %{
              issue_identifier: identifier,
              issue_id: retrying.issue_id,
              status: "retrying",
              running: nil,
              retry: retrying
            }

          completed ->
            %{
              issue_identifier: identifier,
              issue_id: completed.issue_id,
              status: "completed",
              completed: completed
            }

          true ->
            nil
        end
    end
  end

  defp dashboard_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Symphony</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: ui-monospace, monospace; background: #0f0f0f; color: #e0e0e0; padding: 2rem; }
        h1 { font-size: 1.2rem; color: #fff; margin-bottom: 1.5rem; letter-spacing: 0.05em; }
        h2 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.1em; color: #666; margin-bottom: 0.75rem; }
        .section { margin-bottom: 2rem; }
        .card { background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 4px; padding: 1rem; margin-bottom: 0.5rem; }
        .card .id { font-size: 0.85rem; color: #fff; font-weight: bold; margin-bottom: 0.4rem; }
        .card .meta { font-size: 0.75rem; color: #888; line-height: 1.6; }
        .card .msg { font-size: 0.75rem; color: #aaa; margin-top: 0.4rem; white-space: pre-wrap; word-break: break-word; }
        .badge { display: inline-block; padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.65rem; font-weight: bold; text-transform: uppercase; margin-left: 0.5rem; }
        .badge.running { background: #1a3a1a; color: #4caf50; }
        .badge.retrying { background: #3a2a1a; color: #ff9800; }
        .badge.completed { background: #1a2a3a; color: #64b5f6; }
        .stat { display: inline-block; margin-right: 1.5rem; }
        .stat .val { color: #fff; }
        .empty { color: #444; font-size: 0.8rem; padding: 0.5rem 0; }
        .log-link { font-size: 0.65rem; color: #555; text-decoration: none; margin-left: 0.75rem; }
        .log-link:hover { color: #888; }
        .log { margin-top: 0.75rem; border-top: 1px solid #2a2a2a; padding-top: 0.5rem; }
        .log-row { font-size: 0.7rem; line-height: 1.7; display: flex; gap: 0.75rem; flex-wrap: wrap; }
        .log-t { color: #444; min-width: 70px; }
        .log-type { color: #555; min-width: 110px; }
        .updated { font-size: 0.7rem; color: #444; margin-top: 1.5rem; }
      </style>
    </head>
    <body>
      <h1>⬡ Symphony</h1>
      <div id="root">Loading...</div>
      <div class="updated" id="ts"></div>
      <script>
        function fmt(iso) {
          if (!iso) return '—';
          const d = new Date(iso);
          return d.toLocaleTimeString();
        }
        function elapsed(iso) {
          if (!iso) return '';
          const secs = Math.round((Date.now() - new Date(iso)) / 1000);
          if (secs < 60) return secs + 's';
          return Math.floor(secs / 60) + 'm ' + (secs % 60) + 's';
        }
        function eventLog(events) {
          if (!events || events.length === 0) return '';
          const rows = events.map(e => {
            const t = e.timestamp ? new Date(e.timestamp).toLocaleTimeString() : '';
            const type = e.event || '';
            let detail = '';
            if (type === 'tool_call') detail = `<span style="color:#f9a825">${e.tool}</span>: ${esc(e.command || '')}`;
            else if (type === 'tool_result') detail = `<span style="color:#aaa">${esc(e.output || '')}</span>`;
            else if (type === 'model_response') detail = `<span style="color:#80cbc4">${esc(e.message || '')}</span>`;
            else if (type === 'turn_completed') detail = `<span style="color:#4caf50">done — ${esc(e.message || '')}</span>`;
            else detail = esc(e.message || e.error || '');
            return `<div class="log-row"><span class="log-t">${t}</span><span class="log-type">${type}</span>${detail}</div>`;
          }).join('');
          return `<div class="log">${rows}</div>`;
        }
        function esc(s) {
          return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }
        function card(issue, status) {
          const badge = `<span class="badge ${status}">${status}</span>`;
          let meta = '';
          if (status === 'running') {
            const id = issue.issue_identifier;
            meta = `turns: <span class="val">${issue.turn_count}</span> &nbsp; started: <span class="val">${fmt(issue.started_at)}</span> &nbsp; running: <span class="val">${elapsed(issue.started_at)}</span>`;
            const msg = issue.last_message ? `<div class="msg">${issue.last_message}</div>` : '';
            const log = eventLog(issue.event_log);
            const link = `<a class="log-link" href="/api/v1/${id}/log" target="_blank">raw log ↗</a>`;
            return `<div class="card"><div class="id">${id}${badge}${link}</div><div class="meta">${meta}</div>${msg}${log}</div>`;
          } else if (status === 'retrying') {
            const id = issue.issue_identifier;
            meta = `attempt: <span class="val">${issue.attempt}</span> &nbsp; due: <span class="val">${fmt(issue.due_at)}</span>`;
            if (issue.error) meta += ` &nbsp; error: <span class="val">${issue.error}</span>`;
            return `<div class="card"><div class="id">${id}${badge}</div><div class="meta">${meta}</div></div>`;
          } else {
            const id = issue.identifier;
            meta = `completed: <span class="val">${fmt(issue.completed_at)}</span> &nbsp; turns: <span class="val">${issue.turn_count}</span> &nbsp; tokens: <span class="val">${issue.tokens?.total ?? 0}</span>`;
            const log = eventLog(issue.event_log);
            const link = `<a class="log-link" href="/api/v1/${id}/log" target="_blank">raw log ↗</a>`;
            return `<div class="card"><div class="id">${id}${badge}${link}</div><div class="meta">${meta}</div>${log}</div>`;
          }
        }
        function section(title, items, status, emptyMsg) {
          const inner = items.length === 0
            ? `<div class="empty">${emptyMsg}</div>`
            : items.map(i => card(i, status)).join('');
          return `<div class="section"><h2>${title} (${items.length})</h2>${inner}</div>`;
        }
        async function refresh() {
          try {
            const r = await fetch('/api/v1/state');
            const d = await r.json();
            const html = [
              section('Running', d.running || [], 'running', 'No active agents'),
              section('Retrying', d.retrying || [], 'retrying', 'No pending retries'),
              section('Completed', d.completed || [], 'completed', 'None yet this session'),
            ].join('');
            document.getElementById('root').innerHTML = html;
            document.getElementById('ts').textContent = 'Updated ' + new Date().toLocaleTimeString();
          } catch(e) {
            document.getElementById('root').innerHTML = '<div class="empty">Failed to load state</div>';
          }
        }
        refresh();
        setInterval(refresh, 5000);
      </script>
    </body>
    </html>
    """
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
