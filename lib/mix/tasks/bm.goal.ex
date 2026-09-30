defmodule Mix.Tasks.Bm.Goal do
  @shortdoc "Start a BM goal run and follow it in the terminal"

  @moduledoc """
  Starts a goal run in the running BM server and follows it until it ends (plan 14.3).

      mix bm.goal "Add a /health endpoint with a test"
      mix bm.goal "…" --repo ~/code/app --verify "mix test" --budget 0.5
      mix bm.goal "…" --no-wait

  `--repo` defaults to the current directory; `--verify` defaults to the repository's saved
  verify command. The run is also on the web page (the URL is printed). A paused run can be
  resumed there. What the run waits for is printed; `mix bm.attach` answers it in the terminal.
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run(args) do
    {opts, words, _} =
      OptionParser.parse(args,
        strict: [repo: :string, verify: :string, budget: :float, no_wait: :boolean]
      )

    goal = Enum.join(words, " ")
    if goal == "", do: Mix.raise(~s(Give the goal: mix bm.goal "…"))

    CLI.start()

    body = %{
      repo: Path.expand(opts[:repo] || File.cwd!()),
      goal: goal,
      verify_command: opts[:verify],
      budget_usd: opts[:budget]
    }

    case CLI.post("/api/goals", body) do
      {:ok, run} ->
        Mix.shell().info("#{run["label"]} started in #{run["repo"]}\n#{run["url"]}")
        unless opts[:no_wait], do: CLI.follow(run["id"])

      {:error, message} ->
        Mix.raise("Not started: #{message}")
    end
  end
end
