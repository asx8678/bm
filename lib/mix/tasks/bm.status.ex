defmodule Mix.Tasks.Bm.Status do
  @shortdoc "Show one BM run and its tasks"

  @moduledoc """
  Shows a run of the running BM server with its tasks (plan 14.3).

      mix bm.status BM-68
      mix bm.status 68

  After the task lines, when the run waits for the user (a worker's pending approval, or
  changes that wait for Keep or Revert) each pending question is printed with its options,
  followed by the waiting decision, and a hint line pointing at `mix bm.attach` and the run's
  URL.
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

        if run["waiting_for_you"] do
          for approval <- run["approvals"] || [], do: Mix.shell().info(approval_line(approval))

          if is_map(run["decision"]) do
            Mix.shell().info(decision_line(run["decision"]))
          end

          Mix.shell().info("Answer with mix bm.attach #{run["label"]} or at #{run["url"]}")
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("Give the run: mix bm.status BM-68")

  defp approval_line(approval) do
    question = approval["title"] || approval["message"] || "a question (#{approval["method"]})"

    options =
      if approval["method"] == "select" do
        case approval["options"] do
          nil -> ""
          options -> " " <> Enum.join(options, ", ")
        end
      else
        ""
      end

    "  #{question}#{options}"
  end

  defp decision_line(decision) do
    reason = if decision["reason"], do: ": #{decision["reason"]}", else: ""
    "  #{decision["task"]} waits for Keep or Revert#{reason}"
  end
end
