defmodule Bm.Bridge do
  @moduledoc """
  Authoritative handling of requests from BM's pi extensions.

  A request reaches the agent's owner as `{:pi_request, agent_id, request}` (see `Bm.Pi.Agent`).
  The owner calls `handle/5` with its **current assignment** for that agent, which:

    1. checks that the agent's **role** may perform the operation (planners propose tasks,
       workers report results; both ask for authorization of guarded tool calls);
    2. **fences** the request: it is rejected unless the owner has assigned the agent work
       (`"not_assigned"`; a worker needs an attempt) and the request comes from the pi session
       the assignment was made for (`"stale"`);
    3. returns the stored outcome if this `request_id` was already handled (duplicate delivery
       has one logical effect);
    4. otherwise runs the owner's `fun`, **persists** request, attempt and outcome in one
       transaction, and only then returns the outcome for `Bm.Pi.respond/3`.

  Identity comes from the channel: `agent_id` is the adapter the dialog arrived on and the
  request's `session_epoch` is the adapter's, never values supplied by the model. Rejections in
  steps 1 and 2 run nothing and persist nothing.
  """

  import Ecto.Query

  alias Bm.Bridge.Request
  alias Bm.Repo

  @ops %{
    planner: ~w(propose_plan propose_task close_plan authorize),
    worker: ~w(submit_result authorize ask_planner)
  }

  @type role :: :planner | :worker
  @type outcome :: %{required(String.t()) => term()}
  @typedoc "What the owner assigned the agent: the pi session and, for workers, the attempt."
  @type assignment :: %{session_epoch: integer(), attempt_id: integer() | nil} | nil

  @doc "Operations a role may perform."
  def allowed_ops(role), do: Map.get(@ops, role, [])

  @doc """
  Handles one forwarded request under the owner's current `assignment` for the agent. `fun`
  receives the request and returns the outcome map (it must contain `"ok"`); it runs inside the
  transaction that persists the outcome.
  """
  @spec handle(role, String.t(), map(), assignment, (map() -> outcome)) :: outcome
  def handle(role, agent_id, request, assignment, fun) do
    cond do
      request.op not in allowed_ops(role) ->
        %{"ok" => false, "error" => "operation_not_allowed", "op" => request.op}

      not assigned?(role, assignment) ->
        %{"ok" => false, "error" => "not_assigned"}

      request.session_epoch != assignment.session_epoch ->
        %{"ok" => false, "error" => "stale"}

      get(request.request_id) ->
        stored_outcome(request.request_id, agent_id)

      true ->
        persist(role, agent_id, request, assignment, fun)
    end
  end

  @doc """
  Steps 1–3 of `handle/5` without running anything: for requests answered later (a worker's
  `ask_planner` waits for a planner turn, which must not hold a transaction). Returns `:ok`,
  `{:duplicate, outcome}` or `{:error, outcome}`; persist the answer with `record/5`.
  """
  def check(role, agent_id, request, assignment) do
    cond do
      request.op not in allowed_ops(role) ->
        {:error, %{"ok" => false, "error" => "operation_not_allowed", "op" => request.op}}

      not assigned?(role, assignment) ->
        {:error, %{"ok" => false, "error" => "not_assigned"}}

      request.session_epoch != assignment.session_epoch ->
        {:error, %{"ok" => false, "error" => "stale"}}

      get(request.request_id) ->
        {:duplicate, stored_outcome(request.request_id, agent_id)}

      true ->
        :ok
    end
  end

  @doc "Persists an outcome computed outside `handle/5` (see `check/4`); returns the outcome kept."
  def record(role, agent_id, request, assignment, outcome) do
    persist(role, agent_id, request, assignment, fn _request -> outcome end)
  end

  defp assigned?(_role, nil), do: false

  defp assigned?(:worker, assignment),
    do: is_integer(assignment[:session_epoch]) and is_integer(assignment[:attempt_id])

  defp assigned?(_role, assignment), do: is_integer(assignment[:session_epoch])

  defp persist(role, agent_id, request, assignment, fun) do
    Repo.transaction(fn ->
      outcome = fun.(request)

      attrs = %{
        request_id: request.request_id,
        agent_id: agent_id,
        role: Atom.to_string(role),
        op: request.op,
        session_epoch: request.session_epoch,
        attempt_id: assignment[:attempt_id],
        payload: request.payload,
        outcome: outcome
      }

      case %Request{} |> Request.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> outcome
        # A concurrent duplicate committed first: undo this attempt and use its outcome.
        {:error, %{errors: [request_id: _]}} -> Repo.rollback(:duplicate)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, :duplicate} -> stored_outcome(request.request_id, agent_id)
      {:error, reason} -> %{"ok" => false, "error" => "not_persisted: #{inspect(reason)}"}
    end
  end

  # Never re-runs the handler: a duplicate returns what was recorded, or an explicit error.
  # (The concurrent-commit path can't be exercised under the SQL sandbox, which shares one
  # connection; it relies on the unique index on request_id.)
  defp stored_outcome(request_id, agent_id) do
    case get(request_id) do
      %{agent_id: ^agent_id, outcome: outcome} -> outcome
      %{} -> %{"ok" => false, "error" => "request_id_conflict"}
      nil -> %{"ok" => false, "error" => "duplicate_unresolved"}
    end
  end

  defp get(request_id), do: Repo.one(from r in Request, where: r.request_id == ^request_id)
end
