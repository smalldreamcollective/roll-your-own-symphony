defmodule Symphony.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    workflow_path = Application.get_env(:symphony, :workflow_path, nil)
    http_port = Application.get_env(:symphony, :http_port, nil)

    workflow_opts =
      if workflow_path do
        [workflow_path: workflow_path]
      else
        []
      end

    # WorkflowLoader must start before Orchestrator so config is available.
    # Resolve HTTP port from workflow config after the loader is started.
    children = [
      {Symphony.WorkflowLoader, workflow_opts},
      Symphony.Orchestrator
    ]

    # HTTP port from workflow config is deferred until after loader starts.
    # It is added as a child that starts after the supervisor tree is up,
    # so we resolve it here before building the tree (workflow_path may differ).
    children = maybe_add_http_server(children, http_port, workflow_opts)

    opts = [strategy: :one_for_one, name: Symphony.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_http_server(children, cli_port, workflow_opts) do
    port = resolve_http_port(cli_port, workflow_opts)

    if port do
      Logger.info("starting HTTP server port=#{port}")

      http_child =
        {Bandit,
         plug: Symphony.Server.Router,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: port}

      children ++ [http_child]
    else
      children
    end
  end

  defp resolve_http_port(port, _workflow_opts) when is_integer(port), do: port

  defp resolve_http_port(_, workflow_opts) do
    path = Keyword.get(workflow_opts, :workflow_path) || Path.join(File.cwd!(), "WORKFLOW.md")

    case Symphony.WorkflowLoader.load(path) do
      {:ok, %{config: cfg}} -> Symphony.Config.server_port(cfg)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
