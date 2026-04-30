defmodule Symphony.AgentRunner do
  @moduledoc """
  Routes agent runs to the correct backend based on `agent.kind` in cfg.

  Supported kinds:
    ollama  — local Ollama instance (default)
    codex   — OpenAI Codex app-server via stdio
    claude  — Anthropic Claude API
  """

  def run(issue, attempt, workspace_path, cfg, notify_fn, opts \\ []) do
    adapter(cfg).run(issue, attempt, workspace_path, cfg, notify_fn, opts)
  end

  defp adapter(cfg) do
    case get_in(cfg, ["agent", "kind"]) do
      "codex"  -> Symphony.Agent.Codex
      "claude" -> Symphony.Agent.Claude
      _        -> Symphony.Agent.Ollama
    end
  end
end
