defmodule Bm.CLI do
  @moduledoc """
  Shared by the `mix bm.goal`, `mix bm.attach`, `mix bm.runs` and `mix bm.status` terminal
  commands (plans 14.3, 24.2).
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

  ## Following a run (plans 14.3, 21.3, 24.2)

  @poll 2_000
  @ended ~w(done failed cancelled)
  # A server restart is waited out: after it, BM resumes the run by itself when it can.
  @restart_wait 120_000
  # The terminal bell (plan 16.2): the run ended, paused, or waits for the user.
  @bell "\a"

  @doc """
  Follows run `id` until it ends or pauses, printing what changes. With `ask: true`
  (`mix bm.attach`) what the run waits for (Keep or Revert, a worker's approval) is asked once
  in the terminal; an empty answer leaves it for the web page. Without it, it is only printed.
  """
  def follow(id, opts \\ []) do
    loop(id, %{
      ask?: Keyword.get(opts, :ask, false),
      seen: MapSet.new(),
      asked: MapSet.new(),
      recovering: 0,
      down_since: nil
    })
  end

  defp loop(id, st) do
    case fetch("/api/runs/#{id}") do
      {:ok, run} ->
        if st.down_since, do: info("BM answers again.")
        lines = Enum.map(run["tasks"] || [], &task_line/1)
        for line <- lines, not MapSet.member?(st.seen, line), do: info(line)

        st = %{st | seen: MapSet.new(lines), down_since: nil}
        st = st |> approvals(run) |> decision(run)
        report(run, st)

      {:unreachable, message} ->
        now = System.monotonic_time(:millisecond)

        cond do
          st.down_since == nil ->
            info("BM does not answer (restarting?); waiting up to 2 minutes…")
            Process.sleep(@poll)
            loop(id, %{st | down_since: now})

          now - st.down_since < @restart_wait ->
            Process.sleep(@poll)
            loop(id, st)

          true ->
            Mix.raise("Lost the run: #{message}")
        end

      {:error, message} ->
        Mix.raise("Lost the run: #{message}")
    end
  end

  defp report(%{"status" => status} = run, _st) when status in @ended do
    reason = if run["reason"] in [nil, ""], do: "", else: ": #{run["reason"]}"
    info(@bell <> "#{run["label"]} #{status}#{reason} · spent #{money(run["spent_usd"])}")
  end

  defp report(%{"status" => "paused"} = run, st) do
    if recovering?(run["reason"]) and st.recovering < 5 do
      Process.sleep(@poll)
      loop(run["id"], %{st | recovering: st.recovering + 1})
    else
      info(
        @bell <> "#{run["label"]} paused: #{run["reason"]}\nResume or finish it at #{run["url"]}"
      )
    end
  end

  defp report(run, st) do
    Process.sleep(@poll)
    loop(run["id"], %{st | recovering: 0})
  end

  # Right after a restart, BM's recovery pauses a run whose planner was lost, then resumes it by
  # itself or adds why not ("; not resumed by itself: …", "; resuming failed: …"; both strings
  # come from Bm.Workspace.Recovery). A pause without either may be that moment: look again.
  defp recovering?("planner lost: BM stopped" <> rest),
    do: not String.contains?(rest, ["not resumed", "resuming failed"])

  defp recovering?(_reason), do: false

  # A worker's question to the user (plan 24.1), each once.
  defp approvals(st, run) do
    Enum.reduce(run["approvals"] || [], st, fn approval, st ->
      if MapSet.member?(st.asked, approval["id"]) do
        st
      else
        info(@bell <> "#{run["label"]} asks for your approval: #{approval_question(approval)}")
        if approval["title"] && approval["message"], do: info("  #{approval["message"]}")

        if st.ask? do
          with %{} = reply <- ask_approval(approval) do
            sent(post("/api/runs/#{run["id"]}/approvals/#{approval["id"]}", reply))
          end
        else
          info("  Answer it at #{run["url"]} or with mix bm.attach #{run["label"]}")
        end

        %{st | asked: MapSet.put(st.asked, approval["id"])}
      end
    end)
  end

  defp approval_question(approval),
    do: approval["title"] || approval["message"] || "a question (#{approval["method"]})"

  defp ask_approval(%{"method" => "confirm"}) do
    case lower(answer("  Yes or no (d declines, Enter leaves it for the page) [y/n/d]: ")) do
      a when a in ["y", "yes"] -> %{"confirmed" => true}
      a when a in ["n", "no"] -> %{"confirmed" => false}
      "d" -> %{"cancelled" => true}
      _ -> nil
    end
  end

  defp ask_approval(%{"method" => "select"} = approval) do
    options = List.wrap(approval["options"])
    options |> Enum.with_index(1) |> Enum.each(fn {o, i} -> info("    #{i}) #{o}") end)

    case lower(answer("  Number (d declines, Enter leaves it for the page): ")) do
      "d" ->
        %{"cancelled" => true}

      text ->
        case Integer.parse(text || "") do
          {n, ""} when n in 1..length(options)//1 ->
            %{"value" => to_string(Enum.at(options, n - 1))}

          _ ->
            nil
        end
    end
  end

  defp ask_approval(_input_or_editor) do
    case answer("  Your answer (d declines, Enter leaves it for the page): ") do
      "d" -> %{"cancelled" => true}
      text when is_binary(text) and text != "" -> %{"value" => text}
      _ -> nil
    end
  end

  # Changes BM could not accept wait for Keep or Revert (plan 16.2), each once.
  # The attempt holding the lane, as the server's coordinator reports it (plan 28.4): also one
  # BM stopped after it changed files.
  defp decision(st, %{"decision" => %{} = decision} = run) do
    task = Enum.find(run["tasks"] || [], &(&1["key"] == decision["task"])) || %{}
    key = "#{decision["task"]}/#{task["revision"]}/#{decision["attempt_status"]}"

    if MapSet.member?(st.asked, key) do
      st
    else
      info(@bell <> "#{run["label"]} waits for your decision (Keep or Revert) at #{run["url"]}")
      if decision["reason"], do: info("  #{decision["task"]}: #{decision["reason"]}")

      if st.ask? do
        case lower(answer("  Keep or revert the changes (Enter leaves it for the page) [k/r]: ")) do
          a when a in ["k", "keep"] -> sent(post("/api/runs/#{run["id"]}/keep", %{}))
          a when a in ["r", "revert"] -> sent(post("/api/runs/#{run["id"]}/revert", %{}))
          _ -> :ok
        end
      else
        info("  or answer it with mix bm.attach #{run["label"]}")
      end

      %{st | asked: MapSet.put(st.asked, key)}
    end
  end

  defp decision(st, _run), do: st

  defp answer(prompt) do
    case Mix.shell().prompt(prompt) do
      line when is_binary(line) -> String.trim(line)
      _eof -> nil
    end
  end

  defp lower(nil), do: nil
  defp lower(text), do: String.downcase(text)

  defp sent({:ok, _run}), do: info("  Sent.")
  defp sent({:error, message}), do: info("  Not sent: #{message}")

  defp info(text), do: Mix.shell().info(text)
end
