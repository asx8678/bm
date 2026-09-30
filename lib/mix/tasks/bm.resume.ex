defmodule Mix.Tasks.Bm.Resume do
  @shortdoc "Resume a paused goal run's planning"

  @moduledoc """
  Resumes a paused goal run's planning in a new planner session, like the run page's Resume
  planning (plans 7.9, 22.1; the command: 28.3); a run whose plan is closed goes on without a
  planner turn. Talks to the running BM server and refuses with a readable message when the
  coordinator refuses: resuming only works on a paused goal run.

      mix bm.resume BM-68
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run([id | _]) do
    CLI.start()

    case CLI.post("/api/runs/" <> URI.encode(id) <> "/resume", %{}) do
      {:ok, run} ->
        Mix.shell().info("#{run["label"]} resumed")

      {:error, message} ->
        Mix.raise("Not resumed: #{message}")
    end
  end

  def run(_args), do: Mix.raise("Give the run: mix bm.resume BM-68")
end
