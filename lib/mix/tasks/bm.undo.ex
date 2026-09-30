defmodule Mix.Tasks.Bm.Undo do
  @shortdoc "Put one task's files back (paused or finished run)"

  @moduledoc """
  Puts a task's files back as they were before the run did it (plan 15.1, decision D26).
  Talks to the running BM server and refuses with a readable message when the coordinator
  refuses: undoing only works while the run is paused or finished and no dependent task was
  accepted after it.

      mix bm.undo BM-68 my_task_key
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run([id, key | _]) do
    CLI.start()

    case CLI.post("/api/runs/" <> URI.encode(id) <> "/tasks/" <> URI.encode(key) <> "/undo", %{}) do
      {:ok, _run} ->
        Mix.shell().info("Undone: the files of task #{key} are back as before it.")

      {:error, message} ->
        Mix.raise("Not undone: #{message}")
    end
  end

  def run(_args), do: Mix.raise("Give the run and the task: mix bm.undo BM-68 my_task_key")
end
