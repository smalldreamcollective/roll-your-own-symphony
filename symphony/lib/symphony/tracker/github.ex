defmodule Symphony.Tracker.GitHub do
  @moduledoc """
  GitHub Issues tracker adapter.

  State model:
  - Issue state in Symphony is derived from GitHub labels.
  - The special value "closed" in terminal_states maps to GitHub's native
    closed issue state (not a label).
  - All other state names map directly to GitHub label names (case-insensitive).

  Config keys (under `tracker:`):
    repo:        owner/repo-name   (required)
    api_key:     $GITHUB_TOKEN     (required; Personal Access Token or fine-grained PAT)
    active_states:   ["ready", "in-progress"]   (default: ["open"] — maps to open state)
    terminal_states: ["done", "closed"]          (default: ["closed"])

  When active_states is ["open"], any open GitHub issue is a candidate.
  When active_states contains label names, only open issues with one of those
  labels are candidates.
  """

  require Logger

  @base_url "https://api.github.com"
  @page_size 50
  @network_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Required tracker operations
  # ---------------------------------------------------------------------------

  def fetch_candidate_issues(cfg) do
    with :ok <- validate_auth(cfg) do
      active = Symphony.Config.tracker_active_states(cfg)
      fetch_by_states(cfg, active)
    end
  end

  def fetch_issues_by_states(cfg, state_names) do
    with :ok <- validate_auth(cfg) do
      fetch_by_states(cfg, state_names)
    end
  end

  def apply_cancel_label(cfg, issue_id) do
    label = Symphony.Config.tracker_cancel_label(cfg)
    repo = Symphony.Config.tracker_repo(cfg)
    path = "/repos/#{repo}/issues/#{issue_id}/labels"

    case execute_api_call(cfg, "POST", path, %{"labels" => [label]}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_issue_states_by_ids(cfg, issue_ids) do
    with :ok <- validate_auth(cfg) do
      results =
        Enum.map(issue_ids, fn id ->
          fetch_single_issue(cfg, id)
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors != [] do
        {:error, {:partial_fetch_failure, errors}}
      else
        {:ok, Enum.map(results, fn {:ok, issue} -> issue end)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fetching by state
  # ---------------------------------------------------------------------------

  defp fetch_by_states(cfg, state_names) do
    # Partition: "closed" → GitHub closed state; everything else → label names
    {closed_states, label_states} =
      Enum.split_with(state_names, &(String.downcase(&1) == "closed"))

    # "open" is a special passthrough — fetch all open issues (no label filter)
    {open_states, label_states} =
      Enum.split_with(label_states, &(String.downcase(&1) == "open"))

    issues_by_label =
      if label_states != [] do
        case fetch_by_labels(cfg, label_states) do
          {:ok, issues} -> issues
          {:error, _} = err -> throw(err)
        end
      else
        []
      end

    issues_open_all =
      if open_states != [] do
        case fetch_github_issues(cfg, "open", nil) do
          {:ok, issues} -> issues
          {:error, _} = err -> throw(err)
        end
      else
        []
      end

    issues_closed =
      if closed_states != [] do
        case fetch_github_issues(cfg, "closed", nil) do
          {:ok, issues} -> issues
          {:error, _} = err -> throw(err)
        end
      else
        []
      end

    all =
      (issues_by_label ++ issues_open_all ++ issues_closed)
      |> Enum.uniq_by(& &1.id)

    {:ok, all}
  catch
    {:error, _} = err -> err
  end

  defp fetch_by_labels(cfg, label_names) do
    # Fetch open issues for each label separately, then merge
    results =
      Enum.map(label_names, fn label ->
        fetch_github_issues(cfg, "open", label)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors != [] do
      {:error, {:label_fetch_failure, errors}}
    else
      issues =
        results
        |> Enum.flat_map(fn {:ok, list} -> list end)
        |> Enum.uniq_by(& &1.id)

      {:ok, issues}
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub REST API calls
  # ---------------------------------------------------------------------------

  defp fetch_github_issues(cfg, github_state, label) do
    do_paginate_issues(cfg, github_state, label, 1, [])
  end

  defp do_paginate_issues(cfg, github_state, label, page, acc) do
    repo = Symphony.Config.tracker_repo(cfg)
    url = "#{@base_url}/repos/#{repo}/issues"

    params =
      %{state: github_state, per_page: @page_size, page: page}
      |> then(fn p -> if label, do: Map.put(p, :labels, label), else: p end)

    case github_get(cfg, url, params) do
      {:error, _} = err ->
        err

      {:ok, []} ->
        {:ok, acc}

      {:ok, nodes} ->
        issues = Enum.map(nodes, &normalize_issue(&1, cfg))
        all = acc ++ issues

        if length(nodes) < @page_size do
          {:ok, all}
        else
          do_paginate_issues(cfg, github_state, label, page + 1, all)
        end
    end
  end

  defp fetch_single_issue(cfg, issue_id) do
    repo = Symphony.Config.tracker_repo(cfg)
    # issue_id is stored as the issue number string
    url = "#{@base_url}/repos/#{repo}/issues/#{issue_id}"

    case github_get(cfg, url, %{}) do
      {:ok, node} when is_map(node) -> {:ok, normalize_issue(node, cfg)}
      {:error, _} = err -> err
    end
  end

  defp github_get(cfg, url, params) do
    token = Symphony.Config.tracker_api_key(cfg)

    result =
      Req.get(url,
        params: params,
        headers: [
          {"Authorization", "Bearer #{token}"},
          {"Accept", "application/vnd.github+json"},
          {"X-GitHub-Api-Version", "2022-11-28"}
        ],
        receive_timeout: @network_timeout_ms
      )

    case result do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :github_not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_status, status, body}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization
  # ---------------------------------------------------------------------------

  defp normalize_issue(node, cfg) do
    number = node["number"]
    labels = normalize_labels(node["labels"])
    github_state = node["state"] || "open"

    # Derive Symphony state: prefer label-based state, fall back to github_state
    state = derive_state(labels, github_state, cfg)

    %Symphony.Issue{
      id: to_string(number),
      identifier: "##{number}",
      title: node["title"] || "",
      description: node["body"],
      priority: nil,
      state: state,
      branch_name: nil,
      url: node["html_url"],
      labels: labels,
      blocked_by: [],
      created_at: parse_datetime(node["created_at"]),
      updated_at: parse_datetime(node["updated_at"])
    }
  end

  defp derive_state(labels, github_state, cfg) do
    all_known_states =
      (Symphony.Config.tracker_active_states(cfg) ++
         Symphony.Config.tracker_terminal_states(cfg))
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 == "open" or &1 == "closed"))

    # Find the first label that matches a known state
    matched_label =
      Enum.find(labels, fn label ->
        Enum.member?(all_known_states, String.downcase(label))
      end)

    cond do
      matched_label -> matched_label
      github_state == "closed" -> "closed"
      true -> "open"
    end
  end

  defp normalize_labels(nil), do: []

  defp normalize_labels(labels) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> String.downcase(name)
      name when is_binary(name) -> String.downcase(name)
    end)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub API tool extension (for agent use)
  # ---------------------------------------------------------------------------

  @doc """
  Execute a GitHub REST API call on behalf of the agent.
  method: "GET" | "POST" | "PATCH" | "PUT" | "DELETE"
  path: e.g. "/repos/owner/repo/issues/42/comments"
  body: optional map for POST/PATCH requests
  """
  def execute_api_call(cfg, method, path, body \\ nil) do
    token = Symphony.Config.tracker_api_key(cfg)
    url = @base_url <> path

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"Content-Type", "application/json"}
    ]

    req_body = if body, do: Jason.encode!(body), else: ""

    result =
      case String.upcase(method) do
        "GET" -> Req.get(url, headers: headers, receive_timeout: @network_timeout_ms)
        "POST" -> Req.post(url, body: req_body, headers: headers, receive_timeout: @network_timeout_ms)
        "PATCH" -> Req.patch(url, body: req_body, headers: headers, receive_timeout: @network_timeout_ms)
        "PUT" -> Req.put(url, body: req_body, headers: headers, receive_timeout: @network_timeout_ms)
        "DELETE" -> Req.delete(url, headers: headers, receive_timeout: @network_timeout_ms)
        m -> {:error, {:unsupported_method, m}}
      end

    case result do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, b}
      {:ok, %{status: s, body: b}} -> {:error, {:github_api_status, s, b}}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_auth(cfg) do
    cond do
      is_nil(Symphony.Config.tracker_api_key(cfg)) ->
        {:error, :missing_tracker_api_key}

      is_nil(Symphony.Config.tracker_repo(cfg)) ->
        {:error, :missing_tracker_repo}

      true ->
        :ok
    end
  end
end
