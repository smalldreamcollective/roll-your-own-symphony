defmodule Symphony.WorkflowLoader do
  @moduledoc """
  GenServer that owns the parsed WORKFLOW.md, watches the file for changes,
  and notifies the Orchestrator on reload.

  State holds the last successful parse. Invalid reloads keep last known-good
  state and emit an error log.
  """

  use GenServer
  require Logger

  @watcher_name :workflow_watcher

  defstruct [:path, :workflow, :watcher_pid]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns {:ok, workflow} | {:error, reason}"
  def get do
    GenServer.call(__MODULE__, :get)
  end

  # ---------------------------------------------------------------------------
  # init
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :workflow_path, workflow_default_path())
    path = Path.expand(path)

    case load(path) do
      {:ok, workflow} ->
        {:ok, watcher_pid} = start_watcher(path)
        {:ok, %__MODULE__{path: path, workflow: {:ok, workflow}, watcher_pid: watcher_pid}}

      {:error, reason} ->
        Logger.error("workflow load failed path=#{path} reason=#{inspect(reason)}")
        {:ok, watcher_pid} = start_watcher(path)
        {:ok, %__MODULE__{path: path, workflow: {:error, reason}, watcher_pid: watcher_pid}}
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.workflow, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state)
      when path == state.path do
    Logger.info("workflow file changed, reloading path=#{path}")

    new_state =
      case load(path) do
        {:ok, workflow} ->
          Logger.info("workflow reload succeeded path=#{path}")
          notify_orchestrator({:ok, workflow})
          %{state | workflow: {:ok, workflow}}

        {:error, reason} ->
          Logger.error(
            "workflow reload failed path=#{path} reason=#{inspect(reason)}, keeping last known good config"
          )

          notify_orchestrator(state.workflow)
          state
      end

    {:noreply, new_state}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc "Parses a WORKFLOW.md file. Returns {:ok, %{config: map, prompt_template: string}} | {:error, reason}."
  def load(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:error, :missing_workflow_file}

      {:error, reason} ->
        {:error, {:workflow_read_error, reason}}

      {:ok, content} ->
        parse(content)
    end
  end

  def parse(content) do
    if String.starts_with?(content, "---") do
      parse_with_front_matter(content)
    else
      {:ok, %{config: %{}, prompt_template: String.trim(content)}}
    end
  end

  defp parse_with_front_matter(content) do
    # Strip the opening "---" (with optional newline) from the start.
    # Then find the closing "---" on its own line.
    after_open = Regex.replace(~r/\A---\r?\n/, content, "", global: false)

    # Split on the closing "---" line.
    # It may appear at the start of `after_open` (^---) or after a newline (\n---).
    case Regex.split(~r/(?:^|\n)---(?:\r?\n|$)/, after_open, parts: 2) do
      [yaml_part, body_part] ->
        parse_yaml_and_body(yaml_part, body_part)

      [yaml_part] ->
        # No closing delimiter found — treat entire content as prompt (no front matter)
        {:ok, %{config: %{}, prompt_template: String.trim(yaml_part)}}
    end
  end

  defp parse_yaml_and_body(yaml_str, body_str) do
    case YamlElixir.read_from_string(yaml_str) do
      {:ok, config} when is_map(config) ->
        {:ok, %{config: config, prompt_template: String.trim(body_str)}}

      {:ok, _other} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp workflow_default_path do
    Path.join(File.cwd!(), "WORKFLOW.md")
  end

  defp start_watcher(path) do
    dir = Path.dirname(path)

    case FileSystem.start_link(dirs: [dir], name: @watcher_name) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(@watcher_name)
        {:ok, watcher_pid}

      other ->
        Logger.warning("file_system watcher unavailable, hot-reload disabled reason=#{inspect(other)}")
        {:ok, nil}
    end
  end

  defp notify_orchestrator(workflow_result) do
    if pid = Process.whereis(Symphony.Orchestrator) do
      send(pid, {:workflow_reloaded, workflow_result})
    end
  end
end
