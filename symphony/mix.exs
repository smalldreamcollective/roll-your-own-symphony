defmodule Symphony.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Symphony.CLI, app: nil]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Symphony.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5"},
      # JSON
      {:jason, "~> 1.4"},
      # YAML front matter parsing
      {:yaml_elixir, "~> 2.9"},
      # Liquid-compatible template engine
      {:solid, "~> 1.2"},
      # Filesystem watcher for WORKFLOW.md hot-reload
      {:file_system, "~> 1.0"},
      # HTTP server for optional dashboard
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end
end
