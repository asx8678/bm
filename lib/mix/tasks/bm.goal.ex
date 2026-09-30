defmodule Mix.Tasks.Bm.Goal do
  @shortdoc "Start a BM goal run and follow it in the terminal"

  @moduledoc """
  Starts a goal run in the running BM server and follows it until it ends (plan 14.3).

      mix bm.goal "Add a /health endpoint with a test"
      mix bm.goal "…" --repo ~/code/app --verify "mix test" --budget 0.5
      mix bm.goal "…" --no-wait

  `--repo` defaults to the current directory; `--verify` defaults to the repository's saved
  verify command. The run is also on the web page (the URL is printed). A paused run can be
  resumed there.
  """

  use Mix.Task

  alias Bm.CLI

  @poll 2_000
  @ended ~w(done failed cancelled)

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
        unless opts[:no_wait], do: follow(run["id"], %{})

      {:error, message} ->
        Mix.raise("Not started: #{message}")
    end
  end

  # The terminal bell (plan 16.2): the run ended, paused, or waits for a decision.
  @bell "\a"

  # Prints what changed since the last poll; returns when the run ends or pauses.
  defp follow(id, seen) do
    case CLI.get("/api/runs/#{id}") do
      {:ok, run} ->
        lines = Enum.map(run["tasks"] || [], &CLI.task_line/1)
        for line <- lines, not Map.has_key?(seen, line), do: Mix.shell().info(line)
        waiting? = run["waiting_for_you"] == true

        if waiting? and not Map.has_key?(seen, :waiting) do
          Mix.shell().info(
            @bell <> "#{run["label"]} waits for your decision (Keep or Revert) at #{run["url"]}"
          )
        end

        seen = Map.new(lines, &{&1, true})
        seen = if waiting?, do: Map.put(seen, :waiting, true), else: seen
        report(id, run, seen)

      {:error, message} ->
        Mix.raise("Lost the run: #{message}")
    end
  end

  defp report(_id, %{"status" => status} = run, _seen) when status in @ended do
    Mix.shell().info(
      @bell <>
        "#{run["label"]} #{status}: #{run["reason"]} · spent #{CLI.money(run["spent_usd"])}"
    )
  end

  defp report(_id, %{"status" => "paused"} = run, _seen) do
    Mix.shell().info(
      @bell <> "#{run["label"]} paused: #{run["reason"]}\nResume or finish it at #{run["url"]}"
    )
  end

  defp report(id, _run, seen) do
    Process.sleep(@poll)
    follow(id, seen)
  end
end
