defmodule Symphony.Agent.Claude do
  @moduledoc """
  Anthropic Claude API agent adapter.

  Uses the Messages API with native tool use. The message format differs from
  OpenAI/Ollama: tool calls come back as content blocks, and tool results go
  back as user-turn content blocks.

  WORKFLOW.md config:
    agent:
      kind: claude
      model: claude-sonnet-4-6          # default
      api_key: $ANTHROPIC_API_KEY       # default env var
      max_tokens: 8096                  # default
  """

  require Logger

  alias Symphony.Agent.Tools

  @default_model "claude-sonnet-4-6"
  @api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @default_max_tokens 8_096

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def run(issue, attempt, workspace_path, cfg, notify_fn, _opts \\ []) do
    model = cfg_model(cfg)
    api_key = cfg_api_key(cfg)
    max_turns = Symphony.Config.max_turns(cfg)

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_anthropic_api_key}
    else
      workflow = Symphony.WorkflowLoader.get()
      prompt_template = case workflow do
        {:ok, %{prompt_template: pt}} -> pt
        _ -> nil
      end

      case Symphony.Prompt.render(prompt_template, issue, attempt) do
        {:error, reason} ->
          {:error, {:prompt_error, reason}}

        {:ok, prompt_text} ->
          notify_fn.(%{
            event: "session_started",
            timestamp: Tools.utc_now(),
            model: model,
            issue_id: issue.id,
            issue_identifier: issue.identifier
          })

          messages = [%{"role" => "user", "content" => prompt_text}]
          system = Tools.system_prompt(workspace_path, cfg)
          tools = claude_tools(cfg)

          loop(messages, system, tools, workspace_path, cfg, model, api_key, max_turns, 0, notify_fn)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Agent loop
  # ---------------------------------------------------------------------------

  defp loop(messages, system, tools, workspace_path, cfg, model, api_key, max_turns, turn, notify_fn) do
    if turn >= max_turns do
      notify_fn.(%{event: "turn_completed", timestamp: Tools.utc_now(), reason: "max_turns"})
      :ok
    else
      notify_fn.(%{event: "notification", timestamp: Tools.utc_now(), message: "calling #{model}"})

      case call_api(model, api_key, system, messages, tools) do
        {:error, reason} ->
          notify_fn.(%{event: "turn_ended_with_error", timestamp: Tools.utc_now(), reason: inspect(reason)})
          {:error, reason}

        {:ok, response} ->
          stop_reason = response["stop_reason"]
          content_blocks = response["content"] || []
          usage = response["usage"]

          if usage do
            notify_fn.(%{
              event: "notification",
              timestamp: Tools.utc_now(),
              usage: %{
                "input_tokens" => usage["input_tokens"],
                "output_tokens" => usage["output_tokens"]
              }
            })
          end

          # Append the assistant turn
          messages = messages ++ [%{"role" => "assistant", "content" => content_blocks}]

          if stop_reason == "tool_use" do
            # Execute each tool use block and build a single user turn with all results
            tool_results =
              content_blocks
              |> Enum.filter(&(&1["type"] == "tool_use"))
              |> Enum.map(fn block ->
                name = block["name"]
                args = block["input"] || %{}
                tool_use_id = block["id"]

                notify_fn.(%{event: "notification", timestamp: Tools.utc_now(), message: "tool: #{name}"})
                {:ok, output} = Tools.execute(name, args, workspace_path, cfg)

                %{
                  "type" => "tool_result",
                  "tool_use_id" => tool_use_id,
                  "content" => output
                }
              end)

            messages = messages ++ [%{"role" => "user", "content" => tool_results}]

            notify_fn.(%{
              event: "notification",
              timestamp: Tools.utc_now(),
              message: "turn #{turn + 1} completed #{length(tool_results)} tool call(s)"
            })

            loop(messages, system, tools, workspace_path, cfg, model, api_key, max_turns, turn + 1, notify_fn)
          else
            # end_turn — done
            text =
              content_blocks
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map_join("\n", & &1["text"])

            notify_fn.(%{
              event: "turn_completed",
              timestamp: Tools.utc_now(),
              message: String.slice(text, 0, 300)
            })

            :ok
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # API call
  # ---------------------------------------------------------------------------

  defp call_api(model, api_key, system, messages, tools) do
    body = Jason.encode!(%{
      model: model,
      max_tokens: @default_max_tokens,
      system: system,
      tools: tools,
      messages: messages
    })

    case Req.post(@api_url,
           body: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", @anthropic_version},
             {"content-type", "application/json"}
           ],
           receive_timeout: 300_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:anthropic_http_error, status, body}}

      {:error, reason} ->
        {:error, {:anthropic_request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Tool format for Claude API
  # Claude uses {"name", "description", "input_schema"} — not OpenAI's shape.
  # ---------------------------------------------------------------------------

  defp claude_tools(cfg) do
    Tools.all_for(cfg)
    |> Enum.map(fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => tool.parameters
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  defp cfg_model(cfg), do: get_in(cfg, ["agent", "model"]) || @default_model

  defp cfg_api_key(cfg) do
    raw = get_in(cfg, ["agent", "api_key"]) || "$ANTHROPIC_API_KEY"
    case raw do
      "$" <> var -> System.get_env(var)
      val -> val
    end
  end
end
