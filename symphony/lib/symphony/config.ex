defmodule Symphony.Config do
  @moduledoc """
  Typed getters for workflow configuration with defaults, env-var resolution,
  and path normalization. All getters read from the raw map produced by WorkflowLoader.
  """

  @default_poll_interval_ms 30_000
  @default_max_concurrent_agents 10
  @default_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_stall_timeout_ms 300_000
  @default_hooks_timeout_ms 60_000
  @default_active_states ["open"]
  @default_terminal_states ["closed", "Done", "Cancelled", "Canceled", "Duplicate"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_ollama_url "http://localhost:11434"
  @default_agent_model "qwen3:8b"

  # ---------------------------------------------------------------------------
  # Tracker
  # ---------------------------------------------------------------------------

  def tracker_kind(cfg), do: get_in(cfg, ["tracker", "kind"])

  def tracker_endpoint(cfg) do
    get_in(cfg, ["tracker", "endpoint"]) || @default_linear_endpoint
  end

  def tracker_api_key(cfg) do
    raw = get_in(cfg, ["tracker", "api_key"])
    resolve_env(raw)
  end

  # Linear-specific
  def tracker_project_slug(cfg), do: get_in(cfg, ["tracker", "project_slug"])

  # GitHub-specific
  def tracker_repo(cfg), do: get_in(cfg, ["tracker", "repo"])

  def tracker_active_states(cfg) do
    get_in(cfg, ["tracker", "active_states"]) || @default_active_states
  end

  def tracker_terminal_states(cfg) do
    get_in(cfg, ["tracker", "terminal_states"]) || @default_terminal_states
  end

  # ---------------------------------------------------------------------------
  # Polling
  # ---------------------------------------------------------------------------

  def poll_interval_ms(cfg) do
    parse_integer(get_in(cfg, ["polling", "interval_ms"]), @default_poll_interval_ms)
  end

  # ---------------------------------------------------------------------------
  # Workspace
  # ---------------------------------------------------------------------------

  def workspace_root(cfg) do
    raw = get_in(cfg, ["workspace", "root"])

    cond do
      is_nil(raw) ->
        Path.join(System.tmp_dir!(), "symphony_workspaces")

      String.starts_with?(raw, "$") ->
        var = String.slice(raw, 1..-1//1)
        System.get_env(var) || Path.join(System.tmp_dir!(), "symphony_workspaces")

      String.contains?(raw, "/") or String.starts_with?(raw, "~") ->
        Path.expand(raw)

      true ->
        raw
    end
  end

  def artifacts_dir(cfg) do
    case get_in(cfg, ["workspace", "artifacts_dir"]) do
      nil -> nil
      raw -> Path.expand(raw)
    end
  end

  # ---------------------------------------------------------------------------
  # Hooks
  # ---------------------------------------------------------------------------

  def hook_after_create(cfg), do: get_in(cfg, ["hooks", "after_create"])
  def hook_before_run(cfg), do: get_in(cfg, ["hooks", "before_run"])
  def hook_after_run(cfg), do: get_in(cfg, ["hooks", "after_run"])
  def hook_before_remove(cfg), do: get_in(cfg, ["hooks", "before_remove"])

  def hooks_timeout_ms(cfg) do
    raw = get_in(cfg, ["hooks", "timeout_ms"])
    parsed = parse_integer(raw, @default_hooks_timeout_ms)
    if parsed > 0, do: parsed, else: @default_hooks_timeout_ms
  end

  # ---------------------------------------------------------------------------
  # Agent
  # ---------------------------------------------------------------------------

  def max_concurrent_agents(cfg) do
    parse_integer(get_in(cfg, ["agent", "max_concurrent_agents"]), @default_max_concurrent_agents)
  end

  def max_turns(cfg) do
    parse_integer(get_in(cfg, ["agent", "max_turns"]), @default_max_turns)
  end

  def max_retry_backoff_ms(cfg) do
    parse_integer(
      get_in(cfg, ["agent", "max_retry_backoff_ms"]),
      @default_max_retry_backoff_ms
    )
  end

  def max_concurrent_agents_by_state(cfg) do
    raw = get_in(cfg, ["agent", "max_concurrent_agents_by_state"]) || %{}

    raw
    |> Enum.flat_map(fn {k, v} ->
      case parse_integer(v, nil) do
        n when is_integer(n) and n > 0 -> [{String.downcase(to_string(k)), n}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Agent (Ollama)
  # ---------------------------------------------------------------------------

  def agent_model(cfg) do
    get_in(cfg, ["agent", "model"]) || @default_agent_model
  end

  def ollama_url(cfg) do
    raw = get_in(cfg, ["agent", "ollama_url"]) || @default_ollama_url
    String.trim_trailing(raw, "/")
  end

  def stall_timeout_ms(cfg) do
    parse_integer(get_in(cfg, ["agent", "stall_timeout_ms"]), @default_stall_timeout_ms)
  end

  # ---------------------------------------------------------------------------
  # Server extension
  # ---------------------------------------------------------------------------

  def server_port(cfg) do
    case get_in(cfg, ["server", "port"]) do
      nil -> nil
      v -> parse_integer(v, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc "Returns :ok or {:error, reason} for dispatch preflight."
  def validate_for_dispatch(workflow_result) do
    case workflow_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{config: cfg}} ->
        kind = tracker_kind(cfg)

        cond do
          is_nil(kind) or kind == "" ->
            {:error, :missing_tracker_kind}

          kind not in ["linear", "github", "local"] ->
            {:error, {:unsupported_tracker_kind, kind}}

          kind in ["linear", "github"] and
              (is_nil(tracker_api_key(cfg)) or tracker_api_key(cfg) == "") ->
            {:error, :missing_tracker_api_key}

          kind == "linear" and
              (is_nil(tracker_project_slug(cfg)) or tracker_project_slug(cfg) == "") ->
            {:error, :missing_tracker_project_slug}

          kind == "github" and
              (is_nil(tracker_repo(cfg)) or tracker_repo(cfg) == "") ->
            {:error, :missing_tracker_repo}

          true ->
            :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp resolve_env(nil), do: nil
  defp resolve_env("$" <> var), do: System.get_env(var)
  defp resolve_env(value), do: value

  defp parse_integer(nil, default), do: default
  defp parse_integer(v, _default) when is_integer(v), do: v

  defp parse_integer(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_integer(_, default), do: default
end
