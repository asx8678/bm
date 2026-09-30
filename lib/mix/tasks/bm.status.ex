defmodule Mix.Tasks.Bm.Status do
  @shortdoc "Show one BM run and its tasks"

  @moduledoc """
  Shows a run of the running BM server with its tasks (plan 14.3).

      mix bm.status BM-68
      mix bm.status 68
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run([id | _]) do
    CLI.start()

    case CLI.get("/api/runs/" <> URI.encode(id)) do
      {:ok, run} ->
        Mix.shell().info("""
        #{run["label"]} #{run["status"]}#{if run["reason"], do: ": " <> run["reason"], else: ""}
        #{run["goal"]}
        #{run["repo"]} · spent #{CLI.money(run["spent_usd"])}#{if run["budget_usd"], do: " of " <> CLI.money(run["budget_usd"]), else: ""}
        #{run["url"]}
        """)

        for task <- run["tasks"] || [], do: Mix.shell().info(CLI.task_line(task))

      {:error, message} ->
        Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("Give the run: mix bm.status BM-68")
end
