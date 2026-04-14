defmodule Symphony.CLI do
  @moduledoc """
  Escript entry point. Parses CLI flags and starts the application.

  Usage:
    symphony [--workflow PATH] [--port PORT]
  """

  def main(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [workflow: :string, port: :integer]
      )

    if path = Keyword.get(opts, :workflow),
      do: Application.put_env(:symphony, :workflow_path, path)

    if port = Keyword.get(opts, :port),
      do: Application.put_env(:symphony, :http_port, port)

    {:ok, _pid} = Application.ensure_all_started(:symphony)

    # Block forever — the OTP supervisor manages the lifecycle
    Process.sleep(:infinity)
  end
end
