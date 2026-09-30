defmodule Mix.Tasks.Bm.Pause do
  @shortdoc "Pause an active goal run"

  @moduledoc """
  Pauses an active goal run, like the run page's Pause (plans 23.1, 26.4; the command: 28.3):
  its planner stops and nothing new starts; an attempt that is running finishes first. Talks
  to the running BM server and refuses with a readable message when the coordinator refuses:
  pausing only works on an active goal run.

      mix bm.pause BM-68
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run([id | _]) do
    CLI.start()

    case CLI.post("/api/runs/" <> URI.encode(id) <> "/pause", %{}) do
      {:ok, run} ->
        Mix.shell().info("#{run["label"]} paused" <> reason_suffix(run["reason"]))

      {:error, message} ->
        Mix.raise("Not paused: #{message}")
    end
  end

  def run(_args), do: Mix.raise("Give the run: mix bm.pause BM-68")

  defp reason_suffix(nil), do: ""
  defp reason_suffix(reason), do: ": #{reason}"
end
