defmodule Mix.Tasks.Bm.Commit do
  @shortdoc "Commit a finished BM run's accepted changes on your branch"

  @moduledoc """
  Commits the changes a finished run left, on the repository's current branch (plan 15.1,
  decision D26). Only the run's files are committed, exactly as the run left them; refused if
  you changed them since or staged changes in them.

      mix bm.commit BM-68
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run([id | _]) do
    CLI.start()

    case CLI.post("/api/runs/" <> URI.encode(id) <> "/commit", %{}) do
      {:ok, run} ->
        Mix.shell().info(
          "#{run["label"]} committed as #{String.slice(run["commit_sha"], 0, 8)} in #{run["repo"]}"
        )

        # The user's files left out, or an index that stayed locked (plan 36.5).
        case String.split(run["message"] || "", ". ", parts: 2) do
          [_committed, rest] -> Mix.shell().info(rest)
          _ -> :ok
        end

      {:error, message} ->
        Mix.raise("Not committed: #{message}")
    end
  end

  def run(_args), do: Mix.raise("Give the run: mix bm.commit BM-68")
end
