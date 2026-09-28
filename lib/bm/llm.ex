defmodule Bm.LLM do
  @moduledoc "Minimal client for the Anthropic Messages API."

  @url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-5-5"

  @doc "Sends `messages` (`[%{role: \"user\" | \"assistant\", content: String.t()}]`) and returns the reply text."
  def chat(messages) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, "ANTHROPIC_API_KEY is not set. Export it and restart the server."}

      key ->
        Req.post(@url,
          headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
          json: %{model: @model, max_tokens: 4096, messages: messages},
          receive_timeout: 120_000
        )
        |> handle_response()
    end
  end

  defp handle_response({:ok, %{status: 200, body: %{"content" => content}}}) do
    {:ok, content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(& &1["text"])}
  end

  defp handle_response({:ok, %{body: %{"error" => %{"message" => msg}}}}), do: {:error, msg}
  defp handle_response({:ok, %{status: status}}), do: {:error, "Request failed (HTTP #{status})"}
  defp handle_response({:error, exception}), do: {:error, Exception.message(exception)}
end
