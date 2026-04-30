defmodule Symphony.Agent.Codex do
  @moduledoc """
  Codex app-server agent adapter.

  Launches the Codex CLI as a subprocess and speaks the JSON-RPC-like
  line-delimited protocol over stdio.

  WORKFLOW.md config:
    agent:
      kind: codex
      command: codex app-server          # default
      approval_policy: auto              # Codex AskForApproval value
      thread_sandbox: ~                  # Codex SandboxMode value
      turn_sandbox_policy: ~             # Codex SandboxPolicy value
      turn_timeout_ms: 3600000           # default 1 hour
      read_timeout_ms: 5000              # startup handshake timeout
      stall_timeout_ms: 300000           # enforced by Orchestrator
  """

  require Logger

  alias Symphony.Agent.Tools

  @client_name "symphony"
  @client_version "0.1.0"
  @default_command "codex app-server"
  @default_turn_timeout_ms 3_600_000
  @default_read_timeout_ms 5_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def run(issue, attempt, workspace_path, cfg, notify_fn, _opts \\ []) do
    workflow = Symphony.WorkflowLoader.get()
    prompt_template = case workflow do
      {:ok, %{prompt_template: pt}} -> pt
      _ -> nil
    end

    case Symphony.Prompt.render(prompt_template, issue, attempt) do
      {:error, reason} ->
        {:error, {:prompt_error, reason}}

      {:ok, prompt_text} ->
        run_session(issue, prompt_text, workspace_path, cfg, notify_fn)
    end
  end

  # ---------------------------------------------------------------------------
  # Session lifecycle
  # ---------------------------------------------------------------------------

  defp run_session(issue, prompt_text, workspace_path, cfg, notify_fn) do
    command = get_in(cfg, ["agent", "command"]) || @default_command
    read_timeout = parse_int(get_in(cfg, ["agent", "read_timeout_ms"]), @default_read_timeout_ms)
    turn_timeout = parse_int(get_in(cfg, ["agent", "turn_timeout_ms"]), @default_turn_timeout_ms)
    max_turns = Symphony.Config.max_turns(cfg)

    Logger.info("launching codex command=#{command} workspace=#{workspace_path}")

    port =
      Port.open({:spawn, "bash -lc #{Tools.shell_escape(command)}"}, [
        :binary,
        :exit_status,
        {:line, 10 * 1024 * 1024},
        {:cd, workspace_path},
        {:env, [{~c"PWD", String.to_charlist(workspace_path)}]},
        :stderr_to_stdout
      ])

    pid = port_pid(port)

    notify_fn.(%{
      event: "session_started",
      timestamp: Tools.utc_now(),
      codex_app_server_pid: pid,
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    state = %{
      port: port,
      workspace_path: workspace_path,
      cfg: cfg,
      thread_id: nil,
      req_id: 1,
      line_buffer: ""
    }

    result =
      with {:ok, state} <- send_initialize(state, read_timeout),
           {:ok, state} <- send_thread_start(state, workspace_path, read_timeout) do
        run_turn_loop(state, issue, prompt_text, turn_timeout, max_turns, 1, notify_fn)
      end

    close_port(port)

    case result do
      :ok ->
        :ok
      {:error, reason} ->
        notify_fn.(%{event: "startup_failed", timestamp: Tools.utc_now(), error: inspect(reason)})
        {:error, {:codex_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Startup handshake
  # ---------------------------------------------------------------------------

  defp send_initialize(state, timeout) do
    {state, id} = next_id(state)
    msg = %{
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "clientInfo" => %{"name" => @client_name, "version" => @client_version},
        "capabilities" => %{}
      }
    }
    with :ok <- send_msg(state.port, msg),
         :ok <- send_msg(state.port, %{"method" => "initialized", "params" => %{}}),
         {:ok, _} <- await_response(state, id, timeout) do
      {:ok, state}
    end
  end

  defp send_thread_start(state, workspace_path, timeout) do
    {state, id} = next_id(state)
    cfg = state.cfg

    params =
      %{"cwd" => workspace_path}
      |> maybe_put("approvalPolicy", get_in(cfg, ["agent", "approval_policy"]))
      |> maybe_put("sandbox", get_in(cfg, ["agent", "thread_sandbox"]))

    with :ok <- send_msg(state.port, %{"id" => id, "method" => "thread/start", "params" => params}),
         {:ok, result} <- await_response(state, id, timeout) do
      thread_id = get_in(result, ["thread", "id"])
      if thread_id, do: {:ok, %{state | thread_id: thread_id}}, else: {:error, :thread_id_missing}
    end
  end

  # ---------------------------------------------------------------------------
  # Turn loop
  # ---------------------------------------------------------------------------

  defp run_turn_loop(state, issue, prompt_text, turn_timeout, max_turns, turn_number, notify_fn) do
    input =
      if turn_number == 1 do
        prompt_text
      else
        "Continue working on the issue. The previous turn completed. Check the current issue state and continue if there is more to do."
      end

    {state, id} = next_id(state)
    title = "#{issue.identifier}: #{issue.title}"
    cfg = state.cfg

    params =
      %{
        "threadId" => state.thread_id,
        "input" => [%{"type" => "text", "text" => input}],
        "cwd" => state.workspace_path,
        "title" => title
      }
      |> maybe_put("approvalPolicy", get_in(cfg, ["agent", "approval_policy"]))
      |> put_sandbox_policy(get_in(cfg, ["agent", "turn_sandbox_policy"]))

    read_timeout = parse_int(get_in(cfg, ["agent", "read_timeout_ms"]), @default_read_timeout_ms)

    with :ok <- send_msg(state.port, %{"id" => id, "method" => "turn/start", "params" => params}),
         {:ok, result} <- await_response(state, id, read_timeout) do
      turn_id = get_in(result, ["turn", "id"]) || "unknown"
      session_id = "#{state.thread_id}-#{turn_id}"

      notify_fn.(%{event: "notification", timestamp: Tools.utc_now(), session_id: session_id, message: "turn #{turn_number} started"})

      case stream_turn(state, session_id, turn_timeout, notify_fn) do
        {:error, reason} ->
          {:error, reason}

        :ok ->
          # Re-check issue state then continue if still active and turns remain
          case refetch_issue(issue, cfg) do
            {:error, reason} -> {:error, {:issue_refresh_failed, reason}}
            {:ok, refreshed} ->
              terminal = Symphony.Config.tracker_terminal_states(cfg)
              active = Symphony.Config.tracker_active_states(cfg)
              state_lower = String.downcase(refreshed.state)

              cond do
                Enum.any?(terminal, &(String.downcase(&1) == state_lower)) -> :ok
                not Enum.any?(active, &(String.downcase(&1) == state_lower)) -> :ok
                turn_number >= max_turns -> :ok
                true -> run_turn_loop(state, refreshed, prompt_text, turn_timeout, max_turns, turn_number + 1, notify_fn)
              end
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Turn streaming
  # ---------------------------------------------------------------------------

  defp stream_turn(state, session_id, timeout_ms, notify_fn) do
    receive do
      {port, {:data, {:eol, line}}} when port == state.port ->
        full_line = state.line_buffer <> line
        state = %{state | line_buffer: ""}
        handle_line(state, session_id, full_line, timeout_ms, notify_fn)

      {port, {:data, {:noeol, chunk}}} when port == state.port ->
        stream_turn(%{state | line_buffer: state.line_buffer <> chunk}, session_id, timeout_ms, notify_fn)

      {port, {:exit_status, _}} when port == state.port ->
        notify_fn.(%{event: "turn_ended_with_error", timestamp: Tools.utc_now(), session_id: session_id, reason: "port_exit"})
        {:error, :port_exit}
    after
      timeout_ms ->
        notify_fn.(%{event: "turn_ended_with_error", timestamp: Tools.utc_now(), session_id: session_id, reason: "turn_timeout"})
        {:error, :turn_timeout}
    end
  end

  defp handle_line(state, session_id, line, timeout_ms, notify_fn) do
    case Jason.decode(line) do
      {:error, _} ->
        stream_turn(state, session_id, timeout_ms, notify_fn)

      {:ok, msg} ->
        method = msg["method"]

        cond do
          method == "turn/completed" ->
            notify_fn.(%{event: "turn_completed", timestamp: Tools.utc_now(), session_id: session_id, usage: extract_usage(msg)})
            :ok

          method == "turn/failed" ->
            notify_fn.(%{event: "turn_failed", timestamp: Tools.utc_now(), session_id: session_id})
            {:error, :turn_failed}

          method == "turn/cancelled" ->
            notify_fn.(%{event: "turn_cancelled", timestamp: Tools.utc_now(), session_id: session_id})
            {:error, :turn_cancelled}

          method in ["item/tool/requestUserInput", "turn/awaitingInput"] ->
            notify_fn.(%{event: "turn_input_required", timestamp: Tools.utc_now(), session_id: session_id})
            {:error, :turn_input_required}

          method in ["item/tool/approvalRequest", "item/tool/approvalRequested"] ->
            approval_id = msg["id"] || get_in(msg, ["params", "id"])
            notify_fn.(%{event: "approval_auto_approved", timestamp: Tools.utc_now(), session_id: session_id})
            send_msg(state.port, %{"id" => approval_id, "result" => %{"approved" => true}})
            stream_turn(state, session_id, timeout_ms, notify_fn)

          method == "item/tool/call" ->
            tool_name = get_in(msg, ["params", "name"]) || get_in(msg, ["params", "toolName"])
            tool_id = msg["id"] || get_in(msg, ["params", "id"])
            tool_input = get_in(msg, ["params", "input"]) || get_in(msg, ["params", "arguments"]) || %{}

            notify_fn.(%{event: "notification", timestamp: Tools.utc_now(), session_id: session_id, message: "tool: #{tool_name}"})
            {:ok, output} = Tools.execute(tool_name, tool_input, state.workspace_path, state.cfg)

            send_msg(state.port, %{"id" => tool_id, "result" => %{"success" => true, "output" => output}})
            stream_turn(state, session_id, timeout_ms, notify_fn)

          true ->
            notify_fn.(%{event: "notification", timestamp: Tools.utc_now(), session_id: session_id, message: summarize(msg)})
            stream_turn(state, session_id, timeout_ms, notify_fn)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Startup response awaiting
  # ---------------------------------------------------------------------------

  defp await_response(state, expected_id, timeout_ms) do
    receive do
      {port, {:data, {:eol, line}}} when port == state.port ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^expected_id, "result" => result}} -> {:ok, result}
          {:ok, %{"id" => ^expected_id, "error" => err}} -> {:error, {:response_error, err}}
          _ -> await_response(state, expected_id, timeout_ms)
        end

      {port, {:data, {:noeol, _}}} when port == state.port ->
        await_response(state, expected_id, timeout_ms)

      {port, {:exit_status, code}} when port == state.port ->
        {:error, {:port_exit, code}}
    after
      timeout_ms -> {:error, :response_timeout}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp send_msg(port, msg) do
    Port.command(port, Jason.encode!(msg) <> "\n")
    :ok
  rescue
    e -> {:error, {:send_failed, Exception.message(e)}}
  end

  defp next_id(%{req_id: n} = state), do: {%{state | req_id: n + 1}, n}

  defp close_port(port) do
    if Port.info(port) != nil, do: send(port, {self(), :close})
  rescue
    _ -> :ok
  end

  defp port_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> to_string(pid)
      _ -> nil
    end
  end

  defp refetch_issue(issue, cfg) do
    case Symphony.Tracker.fetch_issue_states_by_ids(cfg, [issue.id]) do
      {:ok, [refreshed | _]} -> {:ok, refreshed}
      {:ok, []} -> {:ok, issue}
      {:error, _} = err -> err
    end
  end

  defp extract_usage(msg) do
    params = msg["params"] || %{}
    params["total_token_usage"] || params["usage"] || msg["usage"]
  end

  defp summarize(msg) do
    method = msg["method"] || "unknown"
    params = msg["params"] || %{}
    text = params["text"] || params["message"] || params["content"]
    if text, do: "#{method}: #{String.slice(to_string(text), 0, 200)}", else: method
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp put_sandbox_policy(map, nil), do: map
  defp put_sandbox_policy(map, policy), do: Map.put(map, "sandboxPolicy", %{"type" => policy})

  defp parse_int(nil, default), do: default
  defp parse_int(v, _) when is_integer(v), do: v
  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end
  defp parse_int(_, default), do: default
end
