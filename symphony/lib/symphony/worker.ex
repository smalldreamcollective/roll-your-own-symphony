defmodule Symphony.Worker do
  @moduledoc """
  A supervised Task that runs one agent attempt for one issue.

  Lifecycle (spec §16.5):
  1. Create/reuse workspace.
  2. Run before_run hook.
  3. Start agent session and run turn loop (delegated to AgentRunner).
  4. Run after_run hook (best-effort).
  5. Exit :normal on success, {:error, reason} on failure.

  All agent events are forwarded to the orchestrator via the notify_fn callback.
  """

  require Logger

  @doc """
  Run the agent attempt. This function is the task body — it blocks until done.
  """
  def run(issue, attempt, cfg, notify_fn) do
    Logger.info(
      "worker starting issue_id=#{issue.id} issue_identifier=#{issue.identifier} attempt=#{inspect(attempt)}"
    )

    case Symphony.WorkspaceManager.create_for_issue(issue.identifier, cfg) do
      {:error, reason} ->
        Logger.error(
          "workspace creation failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}"
        )

        {:error, {:workspace_error, reason}}

      {:ok, workspace} ->
        run_with_workspace(issue, attempt, workspace, cfg, notify_fn)
    end
  end

  defp run_with_workspace(issue, attempt, workspace, cfg, notify_fn) do
    case Symphony.WorkspaceManager.run_hook(:before_run, cfg, workspace.path) do
      {:error, reason} ->
        Logger.error(
          "before_run hook failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}"
        )

        {:error, {:before_run_hook_failed, reason}}

      :ok ->
        result = Symphony.AgentRunner.run(issue, attempt, workspace.path, cfg, notify_fn)
        Symphony.WorkspaceManager.run_hook_best_effort(:after_run, cfg, workspace.path)
        result
    end
  end
end
