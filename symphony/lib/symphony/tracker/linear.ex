defmodule Symphony.Tracker.Linear do
  @moduledoc """
  Linear GraphQL tracker adapter.

  All functions return {:ok, result} | {:error, reason}.
  """

  require Logger

  @page_size 50
  @network_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Required tracker operations (spec §11.1)
  # ---------------------------------------------------------------------------

  @doc "Fetch issues in active states for the configured project (paginated)."
  def fetch_candidate_issues(cfg) do
    with :ok <- validate_auth(cfg) do
      fetch_all_pages(cfg, Symphony.Config.tracker_active_states(cfg))
    end
  end

  @doc "Fetch issues by state names — used for startup terminal cleanup."
  def fetch_issues_by_states(cfg, state_names) do
    with :ok <- validate_auth(cfg) do
      fetch_all_pages(cfg, state_names)
    end
  end

  @doc "Fetch current states for specific issue IDs — used for reconciliation."
  def fetch_issue_states_by_ids(cfg, issue_ids) when is_list(issue_ids) do
    with :ok <- validate_auth(cfg) do
      do_fetch_states_by_ids(cfg, issue_ids)
    end
  end

  # ---------------------------------------------------------------------------
  # Pagination
  # ---------------------------------------------------------------------------

  defp fetch_all_pages(cfg, state_names) do
    do_fetch_page(cfg, state_names, nil, [])
  end

  defp do_fetch_page(cfg, state_names, cursor, acc) do
    query = candidate_query()
    slug = Symphony.Config.tracker_project_slug(cfg)

    variables = %{
      "projectSlug" => slug,
      "states" => state_names,
      "first" => @page_size,
      "after" => cursor
    }

    case graphql(cfg, query, variables) do
      {:ok, %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}} ->
        issues = Enum.map(nodes, &normalize_issue/1)
        all = acc ++ issues

        if page_info["hasNextPage"] do
          end_cursor = page_info["endCursor"]

          if is_nil(end_cursor) do
            {:error, :linear_missing_end_cursor}
          else
            do_fetch_page(cfg, state_names, end_cursor, all)
          end
        else
          {:ok, all}
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_fetch_states_by_ids(cfg, issue_ids) do
    query = states_by_ids_query()
    variables = %{"ids" => issue_ids}

    case graphql(cfg, query, variables) do
      {:ok, %{"nodes" => nodes}} ->
        issues =
          nodes
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&normalize_issue/1)

        {:ok, issues}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP transport
  # ---------------------------------------------------------------------------

  defp graphql(cfg, query, variables) do
    endpoint = Symphony.Config.tracker_endpoint(cfg)
    api_key = Symphony.Config.tracker_api_key(cfg)

    body = Jason.encode!(%{"query" => query, "variables" => variables})

    result =
      Req.post(endpoint,
        body: body,
        headers: [
          {"Authorization", api_key},
          {"Content-Type", "application/json"}
        ],
        receive_timeout: @network_timeout_ms
      )

    case result do
      {:ok, %{status: 200, body: body}} ->
        parse_graphql_response(body)

      {:ok, %{status: status}} ->
        {:error, {:linear_api_status, status}}

      {:error, reason} ->
        {:error, {:linear_api_request, reason}}
    end
  end

  defp parse_graphql_response(body) when is_map(body) do
    case body do
      %{"errors" => errors} when is_list(errors) and length(errors) > 0 ->
        {:error, {:linear_graphql_errors, errors}}

      %{"data" => data} when is_map(data) ->
        {:ok, data}

      _ ->
        {:error, :linear_unknown_payload}
    end
  end

  defp parse_graphql_response(_), do: {:error, :linear_unknown_payload}

  # ---------------------------------------------------------------------------
  # Normalization (spec §11.3)
  # ---------------------------------------------------------------------------

  defp normalize_issue(node) do
    %Symphony.Issue{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"] || "",
      description: node["description"],
      priority: parse_priority(node["priority"]),
      state: get_in(node, ["state", "name"]) || "",
      branch_name: node["branchName"],
      url: node["url"],
      labels: normalize_labels(node["labels"]),
      blocked_by: normalize_blockers(node["relations"]),
      created_at: parse_datetime(node["createdAt"]),
      updated_at: parse_datetime(node["updatedAt"])
    }
  end

  defp normalize_labels(%{"nodes" => nodes}) when is_list(nodes) do
    nodes
    |> Enum.map(fn label -> String.downcase(label["name"] || "") end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_labels(_), do: []

  defp normalize_blockers(%{"nodes" => nodes}) when is_list(nodes) do
    nodes
    |> Enum.filter(fn rel -> rel["type"] == "blocks" end)
    |> Enum.map(fn rel ->
      related = rel["relatedIssue"] || %{}
      state = get_in(related, ["state", "name"])

      %{
        id: related["id"],
        identifier: related["identifier"],
        state: state
      }
    end)
  end

  defp normalize_blockers(_), do: []

  defp parse_priority(n) when is_integer(n), do: n
  defp parse_priority(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Auth validation
  # ---------------------------------------------------------------------------

  defp validate_auth(cfg) do
    cond do
      is_nil(Symphony.Config.tracker_api_key(cfg)) ->
        {:error, :missing_tracker_api_key}

      is_nil(Symphony.Config.tracker_project_slug(cfg)) ->
        {:error, :missing_tracker_project_slug}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GraphQL documents
  # ---------------------------------------------------------------------------

  defp candidate_query do
    """
    query CandidateIssues($projectSlug: String!, $states: [String!]!, $first: Int!, $after: String) {
      issues(
        first: $first
        after: $after
        filter: {
          project: { slugId: { eq: $projectSlug } }
          state: { name: { in: $states } }
        }
        orderBy: updatedAt
      ) {
        nodes {
          id
          identifier
          title
          description
          priority
          branchName
          url
          createdAt
          updatedAt
          state { name }
          labels { nodes { name } }
          relations(filter: { type: { eq: "blocks" } }) {
            nodes {
              type
              relatedIssue {
                id
                identifier
                state { name }
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
  end

  defp states_by_ids_query do
    """
    query IssueStatesByIds($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on Issue {
          id
          identifier
          title
          description
          priority
          branchName
          url
          createdAt
          updatedAt
          state { name }
          labels { nodes { name } }
          relations(filter: { type: { eq: "blocks" } }) {
            nodes {
              type
              relatedIssue {
                id
                identifier
                state { name }
              }
            }
          }
        }
      }
    }
    """
  end

  # ---------------------------------------------------------------------------
  # Optional: linear_graphql tool extension (spec §10.5)
  # ---------------------------------------------------------------------------

  @doc """
  Execute a raw GraphQL query/mutation on behalf of the agent tool extension.
  Returns {:ok, response_body} | {:error, reason}.
  """
  def execute_raw_graphql(cfg, query_str, variables \\ nil) do
    case validate_raw_graphql_input(query_str, variables) do
      {:error, _} = err ->
        err

      :ok ->
        vars = variables || %{}
        endpoint = Symphony.Config.tracker_endpoint(cfg)
        api_key = Symphony.Config.tracker_api_key(cfg)

        body = Jason.encode!(%{"query" => query_str, "variables" => vars})

        result =
          Req.post(endpoint,
            body: body,
            headers: [
              {"Authorization", api_key},
              {"Content-Type", "application/json"}
            ],
            receive_timeout: @network_timeout_ms
          )

        case result do
          {:ok, %{status: 200, body: body}} ->
            case body do
              %{"errors" => errors} when is_list(errors) and length(errors) > 0 ->
                {:error, {:graphql_errors, body}}

              %{"data" => _} ->
                {:ok, body}

              _ ->
                {:error, {:unknown_payload, body}}
            end

          {:ok, %{status: status}} ->
            {:error, {:http_status, status}}

          {:error, reason} ->
            {:error, {:transport, reason}}
        end
    end
  end

  defp validate_raw_graphql_input(query_str, variables) do
    cond do
      not is_binary(query_str) or String.trim(query_str) == "" ->
        {:error, :invalid_query}

      not is_nil(variables) and not is_map(variables) ->
        {:error, :invalid_variables}

      true ->
        :ok
    end
  end
end
