defmodule Bm.Review do
  @moduledoc """
  Reviews an attempt's change before BM accepts it (plan 14.1, decision D25). A reader-profile
  pi session, owned by the calling process (the coordinator's review job), reads the task and the
  diff, may look at the repository (read-only tools; its bash is answered by `Bm.Policy` in
  read-only mode) and reports with `submit_result`: `done` approves, `failed` or `blocked`
  rejects, the summary is the reason. Its own `ask_planner` calls get a fixed answer. Its bash
  commands and the policy's answers are returned with the verdict (plan 19.1), so the run page
  shows what the reviewer probed.
  """

  alias Bm.Pi.Profile

  @timeout 300_000
  @max_commands 40

  @doc """
  Runs one review of `prompt` in `root` under agent id `agent_id`. Returns
  `{:ok, %{verdict: :approve | :reject, reason: String.t(), cost: float, commands: [map]}}` or
  `{:error, reason}`. A command is `%{"command" => text, "allowed" => boolean}`, plus `"reason"`
  when the policy refused it.
  """
  def run(agent_id, root, prompt, user_owned) do
    case Profile.start(agent_id, :reader, owner: self(), cwd: root) do
      {:ok, _report} ->
        Bm.Pi.subscribe(agent_id)
        flush(agent_id)
        :ok = Bm.Pi.prompt(agent_id, prompt)
        deadline = System.monotonic_time(:millisecond) + @timeout
        {result, commands} = serve(agent_id, root, user_owned, deadline, false, nil, [])
        cost = safe_cost(agent_id)
        Bm.Pi.stop(agent_id)
        commands = commands |> Enum.reverse() |> Enum.take(@max_commands)

        case result do
          {:ok, %{"status" => "done"} = payload} ->
            {:ok, %{verdict: :approve, reason: summary(payload), cost: cost, commands: commands}}

          {:ok, %{"status" => status} = payload} when status in ["failed", "blocked"] ->
            {:ok, %{verdict: :reject, reason: summary(payload), cost: cost, commands: commands}}

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

  # Answers the session's requests until it is idle again; returns its submitted verdict and the
  # bash commands it asked for (newest first).
  defp serve(id, root, user_owned, deadline, running?, verdict, commands) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    loop = &serve(id, root, user_owned, deadline, &1, &2, &3)

    receive do
      {:pi_request, ^id, %{op: "authorize", payload: payload} = request} ->
        ctx = %{root: root, user_owned: user_owned, mode: :read_only}
        input = payload["input"] || %{}
        decision = Bm.Policy.authorize(payload["tool"], input, ctx)

        outcome =
          case decision do
            :allow -> %{"ok" => true, "allow" => true}
            {:deny, reason} -> %{"ok" => true, "allow" => false, "reason" => reason}
          end

        Bm.Pi.respond(id, request.dialog_id, outcome)
        loop.(running?, verdict, record(commands, payload["tool"], input, decision))

      {:pi_request, ^id, %{op: "submit_result", payload: payload} = request} ->
        Bm.Pi.respond(id, request.dialog_id, %{"ok" => true, "status" => "received"})
        loop.(running?, verdict || payload, commands)

      {:pi_request, ^id, %{op: "ask_planner"} = request} ->
        answer = "You are reviewing; decide from the task and the diff."
        Bm.Pi.respond(id, request.dialog_id, %{"ok" => true, "answer" => answer})
        loop.(running?, verdict, commands)

      {:pi_request, ^id, request} ->
        Bm.Pi.respond(id, request.dialog_id, %{"ok" => false, "error" => "not_allowed"})
        loop.(running?, verdict, commands)

      {:pi, ^id, :status, %{status: :running}} ->
        loop.(true, verdict, commands)

      {:pi, ^id, :status, %{status: :idle}} when running? ->
        {{:ok, verdict}, commands}

      {:pi, ^id, _event, %{status: :exited}} ->
        {if(verdict, do: {:ok, verdict}, else: {:error, :reviewer_exited}), commands}

      {:pi, ^id, _event, _summary} ->
        loop.(running?, verdict, commands)
    after
      remaining -> {if(verdict, do: {:ok, verdict}, else: {:error, :timeout}), commands}
    end
  end

  defp record(commands, "bash", %{"command" => command}, decision) when is_binary(command) do
    entry = %{"command" => String.slice(command, 0, 2_000), "allowed" => decision == :allow}

    case decision do
      {:deny, reason} -> [Map.put(entry, "reason", reason) | commands]
      :allow -> [entry | commands]
    end
  end

  # The reviewer may not edit or write: record the attempt, so the run page shows it tried.
  defp record(commands, tool, input, {:deny, reason}) when tool in ["edit", "write"] do
    command = "#{tool} #{input["path"]}"
    [%{"command" => command, "allowed" => false, "reason" => reason} | commands]
  end

  defp record(commands, _tool, _input, _decision), do: commands
end
