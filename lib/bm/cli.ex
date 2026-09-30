defmodule Bm.CLI do
  @moduledoc """
  Shared by the `mix bm.goal`, `mix bm.runs` and `mix bm.status` terminal commands (plan 14.3).
  They talk to the running BM server's local JSON API (`BmWeb.Api.RunController`) and never
  start BM themselves: a second BEAM would run a second coordinator on the same repository.
  The server is `BM_URL`, or `http://127.0.0.1:$PORT` (default 4001).
  """

  def base_url do
    System.get_env("BM_URL") || "http://127.0.0.1:#{System.get_env("PORT", "4001")}"
  end

  @doc "Starts only what the HTTP client needs."
  def start do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  def get(path), do: path |> fetch() |> plain()

  @doc """
  Like `get/1`, but a server that does not answer gives `{:unreachable, message}` instead of
  `{:error, message}`: `mix bm.goal` waits out a restart (plan 21.3).
  """
  def fetch(path), do: request(:get, path, nil)
  def post(path, body), do: :post |> request(path, body) |> plain()

  defp plain({:unreachable, message}), do: {:error, message}
  defp plain(result), do: result

  defp request(method, path, body) do
    opts = [method: method, url: base_url() <> path, retry: false, receive_timeout: 30_000]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %Req.Response{status: status}} ->
        {:error, "the server answered #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:unreachable, "BM is not running at #{base_url()} (start it with `mix phx.server`)"}

      {:error, %Req.TransportError{} = error} ->
        {:unreachable, Exception.message(error)}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  def money(nil), do: "–"
  def money(n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 4)

  @doc "One line per task: status, key, and the latest attempt's outcome."
  def task_line(task) do
    attempt = task["attempt"] || %{}
    review = if attempt["review"], do: " · review #{attempt["review"]}", else: ""
    error = if attempt["error"], do: " · #{attempt["error"]}", else: ""
    rev = if task["revision"] > 1, do: " (re-planned)", else: ""
    "  #{String.pad_trailing(task["status"], 9)} #{task["key"]}#{rev}#{review}#{error}"
  end
end
