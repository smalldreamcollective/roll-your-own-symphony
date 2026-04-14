defmodule Symphony.Tracker do
  @moduledoc """
  Routes tracker operations to the correct adapter based on `tracker.kind` in cfg.

  Supported kinds: "linear", "github", "local"
  """

  def fetch_candidate_issues(cfg) do
    adapter(cfg).fetch_candidate_issues(cfg)
  end

  def fetch_issues_by_states(cfg, state_names) do
    adapter(cfg).fetch_issues_by_states(cfg, state_names)
  end

  def fetch_issue_states_by_ids(cfg, issue_ids) do
    adapter(cfg).fetch_issue_states_by_ids(cfg, issue_ids)
  end

  defp adapter(cfg) do
    case Symphony.Config.tracker_kind(cfg) do
      "github" -> Symphony.Tracker.GitHub
      "local"  -> Symphony.Tracker.Local
      _        -> Symphony.Tracker.Linear
    end
  end
end
