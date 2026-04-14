defmodule Symphony.WorkspaceManager do
  @moduledoc """
  Workspace lifecycle: creation, reuse, hooks, cleanup.

  Safety invariants (spec §9.5):
  - Workspace path must be a strict subdirectory of workspace root.
  - Workspace keys contain only [A-Za-z0-9._-].
  - Coding agent cwd must equal workspace_path (enforced by AgentRunner).
  """

  require Logger

  @type workspace :: %{
          path: String.t(),
          workspace_key: String.t(),
          created_now: boolean()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Create or reuse the workspace for an issue identifier. Runs after_create hook if new."
  @spec create_for_issue(String.t(), map()) ::
          {:ok, workspace()} | {:error, term()}
  def create_for_issue(identifier, cfg) do
    workspace_key = sanitize_key(identifier)
    root = Symphony.Config.workspace_root(cfg)
    path = Path.join(root, workspace_key)

    with :ok <- assert_under_root(path, root),
         {:ok, created_now} <- ensure_directory(path) do
      workspace = %{path: path, workspace_key: workspace_key, created_now: created_now}

      if created_now do
        case run_hook(:after_create, cfg, path) do
          :ok ->
            {:ok, workspace}

          {:error, reason} ->
            Logger.error(
              "after_create hook failed workspace=#{path} reason=#{inspect(reason)}, removing partial directory"
            )

            File.rm_rf(path)
            {:error, {:hook_failed, :after_create, reason}}
        end
      else
        {:ok, workspace}
      end
    end
  end

  @doc "Remove a workspace directory, running before_remove hook first."
  @spec remove(String.t(), map()) :: :ok
  def remove(path, cfg) do
    if File.dir?(path) do
      run_hook_best_effort(:before_remove, cfg, path)

      case File.rm_rf(path) do
        {:ok, _} ->
          Logger.info("workspace removed path=#{path}")
          :ok

        {:error, reason, file} ->
          Logger.error("workspace removal failed path=#{path} file=#{file} reason=#{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc "Derive workspace path from identifier without creating it."
  def path_for(identifier, cfg) do
    Path.join(Symphony.Config.workspace_root(cfg), sanitize_key(identifier))
  end

  @doc "Copy workspace contents to artifacts_dir before cleanup. No-op if artifacts_dir not configured or workspace missing."
  def archive(workspace_path, cfg) do
    case Symphony.Config.artifacts_dir(cfg) do
      nil ->
        :ok

      artifacts_dir ->
        if File.dir?(workspace_path) do
          key = Path.basename(workspace_path)
          dest = Path.join(artifacts_dir, key)
          File.mkdir_p!(artifacts_dir)

          case File.cp_r(workspace_path, dest) do
            {:ok, _} ->
              Logger.info("workspace archived path=#{workspace_path} dest=#{dest}")
              :ok

            {:error, reason, file} ->
              Logger.warning("workspace archive failed path=#{workspace_path} file=#{file} reason=#{inspect(reason)}")
              :ok
          end
        else
          :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Hooks
  # ---------------------------------------------------------------------------

  @doc "Run a workspace hook, returning :ok or {:error, reason}."
  def run_hook(hook_name, cfg, workspace_path) do
    script = hook_script(hook_name, cfg)

    if is_nil(script) or String.trim(script) == "" do
      :ok
    else
      timeout = Symphony.Config.hooks_timeout_ms(cfg)
      Logger.info("running hook hook=#{hook_name} workspace=#{workspace_path}")
      exec_hook(script, workspace_path, timeout)
    end
  end

  @doc "Run a hook, logging errors but always returning :ok."
  def run_hook_best_effort(hook_name, cfg, workspace_path) do
    case run_hook(hook_name, cfg, workspace_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "hook failed (best-effort, ignoring) hook=#{hook_name} workspace=#{workspace_path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Sanitization (spec §4.2)
  # ---------------------------------------------------------------------------

  @doc "Replace characters outside [A-Za-z0-9._-] with underscores."
  def sanitize_key(identifier) do
    String.replace(identifier, ~r/[^A-Za-z0-9._\-]/, "_")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp hook_script(:after_create, cfg), do: Symphony.Config.hook_after_create(cfg)
  defp hook_script(:before_run, cfg), do: Symphony.Config.hook_before_run(cfg)
  defp hook_script(:after_run, cfg), do: Symphony.Config.hook_after_run(cfg)
  defp hook_script(:before_remove, cfg), do: Symphony.Config.hook_before_remove(cfg)

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        {:ok, false}

      {:ok, _} ->
        {:error, {:path_not_a_directory, path}}

      {:error, :enoent} ->
        case File.mkdir_p(path) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:stat_failed, reason}}
    end
  end

  defp assert_under_root(path, root) do
    abs_path = Path.expand(path)
    abs_root = Path.expand(root)

    # Ensure workspace_path starts with workspace_root + "/"
    if String.starts_with?(abs_path, abs_root <> "/") or abs_path == abs_root do
      :ok
    else
      {:error, {:workspace_outside_root, abs_path, abs_root}}
    end
  end

  defp exec_hook(script, cwd, timeout_ms) do
    port =
      Port.open({:spawn, "bash -lc #{shell_escape(script)}"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd},
        {:env, [{~c"PWD", String.to_charlist(cwd)}]}
      ])

    collect_hook_output(port, timeout_ms, [])
  end

  defp collect_hook_output(port, timeout_ms, output_acc) do
    receive do
      {^port, {:data, data}} ->
        collect_hook_output(port, timeout_ms, [output_acc | [data]])

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        output = IO.iodata_to_binary(output_acc)
        truncated = String.slice(output, 0, 500)
        {:error, {:hook_exit, code, truncated}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :hook_timeout}
    end
  end

  defp shell_escape(script) do
    # Wrap in single quotes, escaping any single quotes within
    "'" <> String.replace(script, "'", "'\\''") <> "'"
  end
end
