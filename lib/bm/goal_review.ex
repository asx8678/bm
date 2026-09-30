defmodule Bm.GoalReview do
  @moduledoc """
  Reviews a goal before planning (plan 12.3): a planner-profile pi session looks at the
  repository (read-only tools; its bash is answered by `Bm.Policy` in read-only mode) and returns
  up to four clarifying questions and a sharper version of the goal. It proposes no tasks and
  starts no run; the calling process owns the session and answers its requests.
  """

  alias Bm.Pi.Profile
  alias Bm.Workspace.Git

  @timeout 150_000

  @doc """
  Reviews `goal` for the checkout at `path`. Returns
  `{:ok, %{questions: [String.t()], goal: String.t(), cost: float}}` or `{:error, reason}`.
  """
  def review(path, goal) do
    with {:ok, root} <- Bm.Runs.canonical_path(path),
         :ok <- Git.check_root(root),
         {:ok, baseline} <- Git.baseline(root) do
      id = "review-#{System.unique_integer([:positive])}"

      case Profile.start(id, :planner, owner: self(), cwd: root) do
        {:ok, _report} ->
          Bm.Pi.subscribe(id)
          flush(id)
          :ok = Bm.Pi.prompt(id, prompt(goal, baseline.user_owned))
          deadline = System.monotonic_time(:millisecond) + @timeout
          result = serve(id, root, baseline.user_owned, deadline, false)
          cost = Bm.Pi.snapshot(id).summary.spend.confirmed
          Bm.Pi.stop(id)

          with {:ok, text} <- result, {:ok, parsed} <- parse(text) do
            {:ok, Map.put(parsed, :cost, cost)}
          end

        {:error, reason} ->
          {:error, {:reviewer_not_started, reason}}
      end
    end
  end

  defp prompt(goal, user_owned) do
    owned = if user_owned == [], do: "none", else: Enum.join(user_owned, ", ")

    """
    You review a goal for BM before it is planned in this repository. Do NOT propose tasks and
    do NOT close any plan. Look at the repository as needed (read, grep, find, ls, read-only
    bash), then reply with ONLY a JSON object and nothing else:

    {"questions": ["...", "..."], "goal": "..."}

    - "questions": at most 4 short questions whose answers would change what gets built (scope,
      where code goes, behaviour at the edges). Leave out anything the repository answers.
      Use [] if the goal is already clear.
    - "goal": the goal rewritten to be specific and self-contained, in the user's intent, in at
      most 6 sentences: name the files and functions involved (no line numbers) and how to check
      the result. Don't invent requirements; leave open what the questions ask.

    Files with the user's uncommitted work (BM won't change them): #{owned}

    Goal:
    #{goal}
    """
  end

  defp flush(id) do
    receive do
      {:pi, ^id, _, _} -> flush(id)
    after
      0 -> :ok
    end
  end

  # Answers the session's requests until it is idle; returns its last message.
  defp serve(id, root, user_owned, deadline, running?) do
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
        serve(id, root, user_owned, deadline, running?)

      {:pi_request, ^id, request} ->
        reply = %{
          "ok" => true,
          "status" => "rejected",
          "reason" => "This is a review; reply with the JSON only."
        }

        Bm.Pi.respond(id, request.dialog_id, reply)
        serve(id, root, user_owned, deadline, running?)

      {:pi, ^id, :status, %{status: :running}} ->
        serve(id, root, user_owned, deadline, true)

      {:pi, ^id, :status, %{status: :idle}} when running? ->
        {:ok, last_reply(id)}

      {:pi, ^id, _event, _summary} ->
        serve(id, root, user_owned, deadline, running?)
    after
      remaining -> {:error, :timeout}
    end
  end

  defp last_reply(id) do
    id
    |> Bm.Pi.snapshot()
    |> Map.fetch!(:transcript)
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant, text: text} when text != "" -> text
      _ -> nil
    end)
  end

  @doc false
  # The JSON object in the reply (models sometimes wrap it in a code fence or add a sentence).
  def parse(text) do
    with [json] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, %{"goal" => goal} = map} when is_binary(goal) <- JSON.decode(json) do
      questions =
        case map["questions"] do
          list when is_list(list) -> list |> Enum.filter(&is_binary/1) |> Enum.take(4)
          _ -> []
        end

      {:ok, %{questions: questions, goal: String.trim(goal)}}
    else
      _ -> {:error, :unreadable_review}
    end
  end
end
