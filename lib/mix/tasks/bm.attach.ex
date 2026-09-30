defmodule Mix.Tasks.Bm.Attach do
  @shortdoc "Follow a BM run in the terminal and answer what it waits for"

  @moduledoc """
  Follows an existing run in the running BM server (plan 24.2), as `mix bm.goal` follows the run
  it starts, and asks in the terminal when the run waits for you: Keep or Revert, or a worker's
  approval (plan 24.1). An empty answer leaves it for the web page.

      mix bm.attach BM-12
      mix bm.attach 12 --watch     # only follow, never ask
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run(args) do
    {opts, words, _} = OptionParser.parse(args, strict: [watch: :boolean])

    id =
      case words do
        [id] -> String.replace_prefix(id, "BM-", "")
        _ -> Mix.raise("Give the run: mix bm.attach BM-12")
      end

    CLI.start()

    case CLI.get("/api/runs/" <> URI.encode(id)) do
      {:ok, run} ->
        Mix.shell().info("#{run["label"]} #{run["status"]} in #{run["repo"]}\n#{run["url"]}")
        CLI.follow(run["id"], ask: not Keyword.get(opts, :watch, false))

      {:error, message} ->
        Mix.raise("No such run: #{message}")
    end
  end
end
