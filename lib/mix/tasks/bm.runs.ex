defmodule Mix.Tasks.Bm.Runs do
  @shortdoc "List recent BM runs"

  @moduledoc """
  Lists recent runs of the running BM server (plan 14.3).

      mix bm.runs            # the 20 most recent
      mix bm.runs calc       # whose goal or repository contains "calc"
      mix bm.runs --limit 50
      mix bm.runs --status active

  `--status` filters by run status: `active`, `paused`, `done`, `failed` or `cancelled`.
  """

  use Mix.Task

  alias Bm.CLI

  @impl true
  def run(args) do
    {opts, words, _} = OptionParser.parse(args, strict: [limit: :integer, status: :string])
    CLI.start()

    query =
      URI.encode_query(
        %{limit: opts[:limit] || 20, q: Enum.join(words, " ")}
        |> maybe_put("status", opts[:status])
      )

    case CLI.get("/api/runs?" <> query) do
      {:ok, %{"runs" => []}} ->
        Mix.shell().info("No runs.")

      {:ok, %{"runs" => runs}} ->
        for run <- runs do
          Mix.shell().info(
            "#{String.pad_trailing(run["label"], 7)} #{String.pad_trailing(run["status"], 9)} " <>
              "#{String.pad_leading(CLI.money(run["spent_usd"]), 8)}  " <>
              "#{Path.basename(run["repo"])}  #{String.slice(run["goal"], 0, 60)}"
          )
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Map.put(query, key, value)
end
