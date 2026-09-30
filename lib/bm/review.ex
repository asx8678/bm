defmodule Bm.Review do
  @moduledoc """
  Reviews an attempt's change before BM accepts it (plan 14.1, decision D25). A reader-profile
  pi session, owned by the calling process (the coordinator's review job), reads the task and the
  diff, may look at the repository (read-only tools; its bash is answered by `Bm.Policy` in
  read-only mode) and reports with `submit_result`: `done` approves, `failed` or `blocked`
  rejects, the summary is the reason. Its own `ask_planner` calls get a fixed answer.
  """

  alias Bm.Pi.Profile

  @timeout 300_000

  @doc """
  Runs one review of `prompt` in `root` under agent id `agent_id`. Returns
  `{:ok, %{verdict: :approve | :reject, reason: String.t(), cost: float}}` or `{:error, reason}`.
  """
  def run(agent_id, root, prompt, user_owned) do
    case Profile.start(agent_id, :reader, owner: self(), cwd: root) do
      {:ok, _report} ->
        Bm.Pi.subscribe(agent_id)
        flush(agent_id)
        :ok = Bm.Pi.prompt(agent_id, prompt)
        deadline = System.monotonic_time(:millisecond) + @timeout
        result = serve(agent_id, root, user_owned, deadline, false, nil)
        cost = safe_cost(agent_id)
        Bm.Pi.stop(agent_id)

        case result do
          {:ok, %{"status" => "done"} = payload} ->
            {:ok, %{verdict: :approve, reason: summary(payload), cost: cost}}

          {:ok, %{"status" => status} = payload} when status in ["failed", "blocked"] ->
            {:ok, %{verdict: :reject, reason: summary(payload), cost: cost}}

          {:ok, nil} ->
            {:error, :no_verdict}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:reviewer_not_started, reason}}
    end
  end

  defp summary(payload), do: String.slice(to_string(payload["summary"] || ""), 0, 2_000)

  defp safe_cost(agent_id) do
    Bm.Pi.snapshot(agent_id).summary.spend.confirmed
  catch
    :exit, _ -> 0.0
  end

  defp flush(id) do
    receive do
      {:pi, ^id, _, _} -> flush(id)
    after
      0 -> :ok
    end
  end

  # Answers the session's requests until it is idle again; returns its submitted verdict.
  defp serve(id, root, user_owned, deadline, running?, verdict) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:pi_request, ^id, %{op: "authorize", payload: payload} = request} ->
        ctx = %{root: root, user_owned: user_owned, mode: :read_only}

        outcome =
          case Bm.Policy.authorize(payload["tool"], payload["input"] || %{}, ctx) do
            :allow -> %{"ok" => true, "allow" => true}
            {:deny, reason} -> %{"ok" => true, "allow" => false, "reason" => reason}
          end

        Bm.Pi.respond(id, request.dialog_id, outcome)
        serve(id, root, user_owned, deadline, running?, verdict)

      {:pi_request, ^id, %{op: "submit_result", payload: payload} = request} ->
        Bm.Pi.respond(id, request.dialog_id, %{"ok" => true, "status" => "received"})
        serve(id, root, user_owned, deadline, running?, verdict || payload)

      {:pi_request, ^id, %{op: "ask_planner"} = request} ->
        answer = "You are reviewing; decide from the task and the diff."
        Bm.Pi.respond(id, request.dialog_id, %{"ok" => true, "answer" => answer})
        serve(id, root, user_owned, deadline, running?, verdict)

      {:pi_request, ^id, request} ->
        Bm.Pi.respond(id, request.dialog_id, %{"ok" => false, "error" => "not_allowed"})
        serve(id, root, user_owned, deadline, running?, verdict)

      {:pi, ^id, :status, %{status: :running}} ->
        serve(id, root, user_owned, deadline, true, verdict)

      {:pi, ^id, :status, %{status: :idle}} when running? ->
        {:ok, verdict}

      {:pi, ^id, _event, %{status: :exited}} ->
        if verdict, do: {:ok, verdict}, else: {:error, :reviewer_exited}

      {:pi, ^id, _event, _summary} ->
        serve(id, root, user_owned, deadline, running?, verdict)
    after
      remaining -> if verdict, do: {:ok, verdict}, else: {:error, :timeout}
    end
  end
end
