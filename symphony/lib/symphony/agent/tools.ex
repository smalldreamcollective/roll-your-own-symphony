defmodule Symphony.Agent.Tools do
  @moduledoc """
  Shared tool definitions and execution logic used by all agent adapters.

  Each adapter is responsible for formatting tool definitions in the shape its
  backend expects, but the execution logic (bash, github_api, linear_graphql)
  lives here.
  """

  require Logger

  @tool_timeout_ms 60_000
  @max_output_bytes 8_000

  # ---------------------------------------------------------------------------
  # Tool definitions (canonical shape — adapters convert as needed)
  # ---------------------------------------------------------------------------

  def bash_definition do
    %{
      name: "bash",
      description:
        "Execute a bash command in the issue workspace directory. " <>
          "Use this to read files, run tests, make changes, and interact with the repo.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The bash command to execute."}
        },
        required: ["command"]
      }
    }
  end

  def linear_graphql_definition do
    %{
      name: "linear_graphql",
      description:
        "Execute a GraphQL query or mutation against Linear. " <>
          "Use this to update issue state, add comments, or read issue details.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "A single GraphQL query or mutation document."},
          variables: %{type: "object", description: "Optional GraphQL variables."}
        },
        required: ["query"]
      }
    }
  end

  def github_api_definition do
    %{
      name: "github_api",
      description:
        "Call the GitHub REST API to interact with issues, comments, labels, and pull requests. " <>
          "Use this to update issue state, add comments, create PRs, or read issue details.",
      parameters: %{
        type: "object",
        properties: %{
          method: %{type: "string", description: "HTTP method: GET, POST, PATCH, PUT, or DELETE."},
          path: %{
            type: "string",
            description:
              "GitHub API path, e.g. /repos/owner/repo/issues/42/comments. " <>
                "The base URL https://api.github.com is prepended automatically."
          },
          body: %{type: "object", description: "Optional request body for POST/PATCH requests."}
        },
        required: ["method", "path"]
      }
    }
  end

  @doc "Returns the tracker tool definition for the configured tracker kind."
  def tracker_tool_definition(cfg) do
    case Symphony.Config.tracker_kind(cfg) do
      "github" -> github_api_definition()
      _ -> linear_graphql_definition()
    end
  end

  @doc "Returns [bash_def, tracker_def] for the given config."
  def all_for(cfg) do
    [bash_definition(), tracker_tool_definition(cfg)]
  end

  # ---------------------------------------------------------------------------
  # Tool execution
  # ---------------------------------------------------------------------------

  @doc "Execute a named tool call. Returns {:ok, output_string} always (errors become output)."
  def execute(name, args, workspace_path, cfg) do
    Logger.info("tool_call tool=#{name}")
    t0 = :erlang.monotonic_time(:millisecond)

    result =
      case name do
        "bash" -> run_bash(args["command"], workspace_path)
        "linear_graphql" -> run_linear_graphql(args, cfg)
        "github_api" -> run_github_api(args, cfg)
        other -> {:error, "unsupported tool: #{other}"}
      end

    elapsed = :erlang.monotonic_time(:millisecond) - t0

    case result do
      {:ok, output} ->
        Logger.info("tool_result tool=#{name} elapsed_ms=#{elapsed} output=#{String.slice(output, 0, 300)}")
        {:ok, output}

      {:error, reason} ->
        Logger.warning("tool_error tool=#{name} elapsed_ms=#{elapsed} reason=#{inspect(reason)}")
        {:ok, "ERROR: #{reason}"}
    end
  end

  # ---------------------------------------------------------------------------
  # bash
  # ---------------------------------------------------------------------------

  defp run_bash(nil, _), do: {:error, "missing command"}
  defp run_bash("", _), do: {:error, "empty command"}

  defp run_bash(command, workspace_path) do
    Logger.info("bash cwd=#{workspace_path} command=#{String.slice(command, 0, 200)}")

    port =
      Port.open({:spawn, "bash -lc #{shell_escape(command)}"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, workspace_path},
        {:env, [{~c"PWD", String.to_charlist(workspace_path)}]}
      ])

    collect_output(port, @tool_timeout_ms, [])
  end

  defp collect_output(port, timeout_ms, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout_ms, [acc | [data]])

      {^port, {:exit_status, 0}} ->
        {:ok, truncate(IO.iodata_to_binary(acc))}

      {^port, {:exit_status, code}} ->
        {:ok, "Exit #{code}:\n#{truncate(IO.iodata_to_binary(acc))}"}
    after
      timeout_ms ->
        Port.close(port)
        {:error, "command timed out after #{timeout_ms}ms"}
    end
  end

  defp truncate(output) do
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n... (truncated)"
    else
      output
    end
  end

  # ---------------------------------------------------------------------------
  # linear_graphql
  # ---------------------------------------------------------------------------

  defp run_linear_graphql(args, cfg) do
    case Symphony.Tracker.Linear.execute_raw_graphql(cfg, args["query"], args["variables"]) do
      {:ok, body} -> {:ok, Jason.encode!(body)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ---------------------------------------------------------------------------
  # github_api
  # ---------------------------------------------------------------------------

  defp run_github_api(args, cfg) do
    path = args["path"]

    if is_nil(path) or String.trim(path) == "" do
      {:error, "missing path"}
    else
      case Symphony.Tracker.GitHub.execute_api_call(cfg, args["method"] || "GET", path, args["body"]) do
        {:ok, body} -> {:ok, Jason.encode!(body)}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # System prompt
  # ---------------------------------------------------------------------------

  @doc "Build the system prompt appropriate for the configured tracker."
  def system_prompt(workspace_path, cfg) do
    {tracker_tool_desc, tracker_done} =
      case Symphony.Config.tracker_kind(cfg) do
        "github" ->
          {
            "- `github_api`: call the GitHub REST API to update issues, add comments, or create PRs.",
            "Close or label the GitHub issue when your work is complete."
          }

        _ ->
          {
            "- `linear_graphql`: run GraphQL queries/mutations against Linear to update issue state or add comments.",
            "Update the Linear issue state when your work is complete."
          }
      end

    """
    You are a coding agent working inside an isolated workspace directory.

    Your workspace is: #{workspace_path}

    You have two tools:
    - `bash`: run any shell command inside your workspace — read files, run tests, make changes, commit code.
    #{tracker_tool_desc}

    Work methodically:
    1. Read relevant code to understand the context.
    2. Make the necessary changes.
    3. Run tests if a test suite exists.
    4. #{tracker_done}

    Provide a brief summary when done. Do not ask for clarification — use your best judgement.
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def shell_escape(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
  def utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
