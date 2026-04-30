defmodule Symphony.Agent.Ollama do
  @moduledoc """
  Ollama agent adapter.

  Runs a multi-turn chat loop against a local Ollama instance using the
  `/api/chat` endpoint with tool calling.

  WORKFLOW.md config:
    agent:
      kind: ollama
      model: qwen3:8b                        # default
      ollama_url: http://localhost:11434      # default
  """

  require Logger

  alias Symphony.Agent.Tools

  @default_model "qwen3:8b"
  @default_ollama_url "http://localhost:11434"
  @default_max_tokens 8_192

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def run(issue, attempt, workspace_path, cfg, notify_fn, opts \\ []) do
    model = cfg_model(cfg)
    ollama_url = cfg_url(cfg)
    max_turns = Symphony.Config.max_turns(cfg)

    notify_fn.(%{
      event: "session_started",
      timestamp: Tools.utc_now(),
      model: model,
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    case build_initial_messages(issue, attempt, workspace_path, cfg, opts) do
      {:error, reason} ->
        {:error, reason}

      {:ok, messages} ->
        loop(messages, workspace_path, cfg, model, ollama_url, max_turns, 0, notify_fn)
    end
  end

  defp build_initial_messages(issue, attempt, workspace_path, cfg, opts) do
    case Keyword.get(opts, :resume_messages) do
      nil ->
        workflow = Symphony.WorkflowLoader.get()
        prompt_template = case workflow do
          {:ok, %{prompt_template: pt}} -> pt
          _ -> nil
        end

        case Symphony.Prompt.render(prompt_template, issue, attempt) do
          {:error, reason} -> {:error, {:prompt_error, reason}}
          {:ok, prompt_text} ->
            {:ok, [
              %{role: "system", content: Tools.system_prompt(workspace_path, cfg)},
              %{role: "user", content: prompt_text}
            ]}
        end

      saved ->
        {:ok, saved ++ [%{role: "user", content: "The issue is still open. Please continue working on it — pick up where you left off."}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Agent loop
  # ---------------------------------------------------------------------------

  defp loop(messages, workspace_path, cfg, model, ollama_url, max_turns, turn, notify_fn) do
    if turn >= max_turns do
      notify_fn.(%{event: "turn_completed", timestamp: Tools.utc_now(), reason: "max_turns"})
      notify_fn.(%{event: "chat_snapshot", messages: messages})
      :ok
    else
      notify_fn.(%{event: "notification", timestamp: Tools.utc_now(), message: "calling #{model}"})

      case chat(ollama_url, model, messages, cfg) do
        {:error, reason} ->
          Logger.error("ollama chat failed model=#{model} reason=#{inspect(reason)}")
          notify_fn.(%{event: "turn_ended_with_error", timestamp: Tools.utc_now(), reason: inspect(reason)})
          {:error, reason}

        {:ok, message} ->
          tool_calls = message["tool_calls"] || []
          content = message["content"] || ""
          messages = messages ++ [normalize_message(message)]

          Logger.debug("ollama response model=#{model} tool_calls=#{length(tool_calls)} content=#{String.slice(content, 0, 200)}")

          if content != "" do
            notify_fn.(%{
              event: "model_response",
              timestamp: Tools.utc_now(),
              turn: turn + 1,
              message: String.slice(content, 0, 500)
            })
          end

          if tool_calls == [] do
            notify_fn.(%{
              event: "turn_completed",
              timestamp: Tools.utc_now(),
              turn: turn + 1,
              message: String.slice(content, 0, 300)
            })
            notify_fn.(%{event: "chat_snapshot", messages: messages})
            :ok
          else
            messages =
              Enum.reduce(tool_calls, messages, fn call, msgs ->
                name = get_in(call, ["function", "name"])
                raw_args = get_in(call, ["function", "arguments"]) || %{}
                args = decode_args(raw_args)
                command = args["command"] || args["query"] || args["path"] || ""

                notify_fn.(%{
                  event: "tool_call",
                  timestamp: Tools.utc_now(),
                  turn: turn + 1,
                  tool: name,
                  command: String.slice(to_string(command), 0, 300)
                })

                {:ok, output} = Tools.execute(name, args, workspace_path, cfg)

                notify_fn.(%{
                  event: "tool_result",
                  timestamp: Tools.utc_now(),
                  turn: turn + 1,
                  tool: name,
                  output: String.slice(output, 0, 500)
                })

                msgs ++ [%{role: "tool", content: output}]
              end)

            loop(messages, workspace_path, cfg, model, ollama_url, max_turns, turn + 1, notify_fn)
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp chat(ollama_url, model, messages, cfg) do
    tools = Enum.map(Tools.all_for(cfg), fn t ->
      %{type: "function", function: t}
    end)

    base = %{
      model: model,
      messages: messages,
      tools: tools,
      stream: false,
      options: %{num_predict: @default_max_tokens}
    }

    body =
      case get_in(cfg, ["agent", "think"]) do
        nil -> base
        val -> Map.put(base, :think, val)
      end
      |> Jason.encode!()

    case Req.post(ollama_url <> "/api/chat",
           body: body,
           headers: [{"Content-Type", "application/json"}],
           receive_timeout: 300_000) do
      {:ok, %{status: 200, body: %{"message" => msg}}} -> {:ok, msg}
      {:ok, %{status: s, body: b}} -> {:error, {:ollama_http_error, s, b}}
      {:error, reason} -> {:error, {:ollama_request_failed, reason}}
    end
  end

  # Normalize assistant messages before re-sending — ensures tool_call arguments
  # are maps, not double-encoded JSON strings, which causes Ollama 500 errors.
  defp normalize_message(%{"tool_calls" => tool_calls} = message) when is_list(tool_calls) do
    normalized = Enum.map(tool_calls, fn call ->
      case get_in(call, ["function", "arguments"]) do
        args when is_binary(args) ->
          decoded = decode_args(args)
          put_in(call, ["function", "arguments"], decoded)
        _ ->
          call
      end
    end)
    %{message | "tool_calls" => normalized}
  end
  defp normalize_message(message), do: message

  defp decode_args(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} -> map
      _ -> %{}
    end
  end
  defp decode_args(map) when is_map(map), do: map
  defp decode_args(_), do: %{}

  defp cfg_model(cfg), do: get_in(cfg, ["agent", "model"]) || @default_model
  defp cfg_url(cfg) do
    raw = get_in(cfg, ["agent", "ollama_url"]) || @default_ollama_url
    String.trim_trailing(raw, "/")
  end
end
