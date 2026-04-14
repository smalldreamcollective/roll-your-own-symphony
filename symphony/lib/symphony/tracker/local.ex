defmodule Symphony.Tracker.Local do
  @moduledoc """
  Local filesystem issue tracker for testing.

  Each issue is a YAML file in a configured directory. The tracker reads,
  filters, and normalizes those files into the standard Symphony.Issue model.

  The agent can update issue state directly by editing the YAML files with
  bash — no special tool needed.

  Directory structure:
    issues/
      ISSUE-1.yaml
      ISSUE-2.yaml

  Issue file format:
    id: "1"                          # required; unique string
    identifier: "ISSUE-1"           # required; used for workspace naming
    title: "Fix the login bug"       # required
    description: |                  # optional
      Longer description here.
    state: "Todo"                    # required
    priority: 1                      # optional; integer 1-4
    labels: []                       # optional; list of strings
    url: ~                           # optional

  WORKFLOW.md config:
    tracker:
      kind: local
      issues_dir: ./issues           # path relative to cwd, or absolute
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
        - Cancelled
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Required tracker operations
  # ---------------------------------------------------------------------------

  def fetch_candidate_issues(cfg) do
    active = Symphony.Config.tracker_active_states(cfg)
    fetch_by_states(cfg, active)
  end

  def fetch_issues_by_states(cfg, state_names) do
    fetch_by_states(cfg, state_names)
  end

  def fetch_issue_states_by_ids(cfg, issue_ids) do
    with {:ok, all} <- load_all(cfg) do
      found = Enum.filter(all, fn issue -> issue.id in issue_ids end)
      {:ok, found}
    end
  end

  # ---------------------------------------------------------------------------
  # Core loading
  # ---------------------------------------------------------------------------

  defp fetch_by_states(cfg, state_names) do
    normalized = Enum.map(state_names, &String.downcase/1)

    with {:ok, all} <- load_all(cfg) do
      matching =
        Enum.filter(all, fn issue ->
          String.downcase(issue.state) in normalized
        end)

      {:ok, matching}
    end
  end

  defp load_all(cfg) do
    dir = issues_dir(cfg)

    case File.ls(dir) do
      {:error, :enoent} ->
        Logger.warning("local tracker issues_dir not found dir=#{dir}")
        {:ok, []}

      {:error, reason} ->
        {:error, {:local_tracker_dir_error, reason}}

      {:ok, files} ->
        issues =
          files
          |> Enum.filter(&String.ends_with?(&1, ".yaml"))
          |> Enum.flat_map(fn file ->
            path = Path.join(dir, file)
            case load_file(path) do
              {:ok, issue} -> [issue]
              {:error, reason} ->
                Logger.warning("skipping issue file path=#{path} reason=#{inspect(reason)}")
                []
            end
          end)

        {:ok, issues}
    end
  end

  defp load_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} when is_map(data) <- YamlElixir.read_from_string(content) do
      normalize(data, path)
    else
      {:ok, _} -> {:error, {:not_a_map, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization
  # ---------------------------------------------------------------------------

  defp normalize(data, path) do
    id = to_string(data["id"] || Path.basename(path, ".yaml"))
    identifier = to_string(data["identifier"] || id)
    title = data["title"]
    state = data["state"]

    cond do
      is_nil(title) or title == "" ->
        {:error, {:missing_title, path}}

      is_nil(state) or state == "" ->
        {:error, {:missing_state, path}}

      true ->
        issue = %Symphony.Issue{
          id: id,
          identifier: identifier,
          title: title,
          description: data["description"],
          priority: parse_priority(data["priority"]),
          state: state,
          branch_name: data["branch_name"],
          url: data["url"] || Path.expand(path),
          labels: normalize_labels(data["labels"]),
          blocked_by: normalize_blockers(data["blocked_by"]),
          created_at: parse_datetime(data["created_at"]),
          updated_at: parse_datetime(data["updated_at"])
        }

        {:ok, issue}
    end
  end

  defp normalize_labels(nil), do: []
  defp normalize_labels(labels) when is_list(labels) do
    Enum.map(labels, &String.downcase(to_string(&1)))
  end

  defp normalize_blockers(nil), do: []
  defp normalize_blockers(blockers) when is_list(blockers) do
    Enum.map(blockers, fn b ->
      %{
        id: to_string(b["id"] || ""),
        identifier: to_string(b["identifier"] || ""),
        state: b["state"]
      }
    end)
  end

  defp parse_priority(nil), do: nil
  defp parse_priority(n) when is_integer(n), do: n
  defp parse_priority(_), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  defp issues_dir(cfg) do
    raw = get_in(cfg, ["tracker", "issues_dir"]) || "./issues"
    Path.expand(raw)
  end
end
