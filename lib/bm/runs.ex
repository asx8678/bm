defmodule Bm.Runs do
  @moduledoc """
  Durable state of BM's work (decision D13): workspaces, runs, tasks and attempts in Postgres.

  One unfinished run per workspace is enforced by the database (`start_run/3` returns
  `{:error, :workspace_busy}`). Attempts move only along `Bm.Runs.Attempt.transitions/0`, and
  `transition_attempt/3` applies a move only if the stored status is still the one the caller saw.
  """

  import Ecto.Query

  alias Bm.Repo
  alias Bm.Runs.{Attempt, Delivery, Run, Task, Workspace}

  ## Workspaces

  @doc """
  Returns the workspace for `path`, creating it if needed. The path is canonical: absolute, with
  symlinks resolved (on macOS `/tmp/x` and `/private/tmp/x` are the same checkout).
  """
  def ensure_workspace(path, attrs \\ %{}) do
    with {:ok, canonical} <- canonical_path(path) do
      case Repo.get_by(Workspace, path: canonical) do
        nil ->
          %Workspace{}
          |> Workspace.changeset(Map.put(attrs, :path, canonical))
          |> Repo.insert(on_conflict: :nothing, conflict_target: :path)
          |> case do
            # Another process created it first: on_conflict returned a struct without an id.
            {:ok, %Workspace{id: nil}} -> {:ok, Repo.get_by!(Workspace, path: canonical)}
            other -> other
          end

        workspace ->
          {:ok, workspace}
      end
    end
  end

  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace |> Workspace.changeset(attrs) |> Repo.update()
  end

  @doc "Absolute path of an existing directory with symlinks resolved."
  def canonical_path(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      case System.cmd("pwd", ["-P"], cd: expanded) do
        {out, 0} -> {:ok, String.trim(out)}
        {out, _} -> {:error, {:canonical_path, String.trim(out)}}
      end
    else
      {:error, {:not_a_directory, expanded}}
    end
  end

  ## Runs

  @doc """
  Starts a run in `workspace`. `attrs`: `:goal` (required), `:budget_usd`, `:plan_open`,
  `:baseline`. Returns `{:error, :workspace_busy}` while another run there is unfinished.
  """
  def start_run(%Workspace{id: workspace_id}, attrs) do
    %Run{workspace_id: workspace_id}
    |> Run.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, run} ->
        {:ok, run}

      {:error, changeset} ->
        if busy?(changeset), do: {:error, :workspace_busy}, else: {:error, changeset}
    end
  end

  defp busy?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field == :workspace_id and opts[:constraint] == :unique
    end)
  end

  @doc "Records the verify command's result on the checkout before the first attempt."
  def set_baseline_verify(%Run{} = run, result) when is_map(result) do
    run |> Ecto.Changeset.change(baseline_verify: result) |> Repo.update()
  end

  @doc "The workspace's unfinished (`:active` or `:paused`) run, or nil."
  def get_unfinished_run(%Workspace{id: workspace_id}) do
    Repo.one(
      from r in Run,
        where: r.workspace_id == ^workspace_id and r.status in ^Run.unfinished_statuses()
    )
  end

  def get_run!(id), do: Repo.get!(Run, id)

  @doc "A run with its workspace, or nil."
  def get_run_with_workspace(id) do
    Repo.one(from r in Run, where: r.id == ^id, preload: :workspace)
  end

  @doc "Ids of the workspace's runs, newest first."
  def list_run_ids(%Workspace{id: workspace_id}) do
    Repo.all(
      from r in Run, where: r.workspace_id == ^workspace_id, order_by: [desc: r.id], select: r.id
    )
  end

  @doc "Every known workspace, most recently used first."
  def list_workspaces do
    Repo.all(from w in Workspace, order_by: [desc: w.updated_at, desc: w.id])
  end

  @doc """
  Runs whose goal or workspace path contains `text` (case-insensitive; blank matches all), with
  status `status` (nil for any), most recently updated first, at most `limit`, with their
  workspaces. Returns `{runs, more?}`.
  """
  def search_runs(text, status, limit) do
    pattern = "%" <> String.replace(String.trim(text || ""), ~r/[\\%_]/, &("\\" <> &1)) <> "%"

    query =
      from r in Run,
        join: w in assoc(r, :workspace),
        where: ilike(r.goal, ^pattern) or ilike(w.path, ^pattern),
        order_by: [desc: r.updated_at, desc: r.id],
        limit: ^(limit + 1),
        preload: [workspace: w]

    query = if status, do: where(query, [r], r.status == ^status), else: query
    runs = Repo.all(query)
    {Enum.take(runs, limit), length(runs) > limit}
  end

  @doc "The most recently updated runs, with their workspaces."
  def list_recent_runs(limit \\ 20) do
    Repo.all(
      from r in Run,
        order_by: [desc: r.updated_at, desc: r.id],
        limit: ^limit,
        preload: :workspace
    )
  end

  @doc """
  Ends a run as `:done`, `:failed` or `:cancelled`; this releases the workspace. `reason` says
  why, in words (kept in `status_reason`).
  """
  def finish_run(%Run{} = run, status, reason \\ nil)
      when status in [:done, :failed, :cancelled] do
    run
    |> Run.status_changeset(status)
    |> Ecto.Changeset.change(status_reason: reason)
    |> Repo.update()
  end

  @doc "Sets fields BM manages on a run: `plan_open`, `planner`, `status_reason`."
  def update_run(%Run{} = run, attrs) do
    run
    |> Ecto.Changeset.change(Map.take(Map.new(attrs), [:plan_open, :planner, :status_reason]))
    |> Repo.update()
  end

  def cancel_run(%Run{} = run), do: finish_run(run, :cancelled)

  @doc "Pauses a run (e.g. after recovery); it keeps the workspace until finished."
  def pause_run(%Run{status: :active} = run, reason \\ nil) do
    run
    |> Run.status_changeset(:paused)
    |> Ecto.Changeset.change(status_reason: reason || run.status_reason)
    |> Repo.update()
  end

  def resume_run(%Run{status: :paused} = run) do
    run
    |> Run.status_changeset(:active)
    |> Ecto.Changeset.change(status_reason: nil)
    |> Repo.update()
  end

  @doc "Active runs driven by a planner (goal runs), with their workspaces."
  def list_active_goal_runs do
    Repo.all(
      from r in Run,
        where: r.status == :active and not is_nil(r.planner),
        preload: :workspace
    )
  end

  ## Tasks

  @doc "Creates a task in `run`. Validation against the plan happens before (phase 7)."
  def create_task(%Run{id: run_id}, attrs) do
    %Task{run_id: run_id} |> Task.create_changeset(attrs) |> Repo.insert()
  end

  def get_task!(id), do: Repo.get!(Task, id)

  def list_tasks(%Run{id: run_id}) do
    Repo.all(from t in Task, where: t.run_id == ^run_id, order_by: [t.inserted_at, t.id])
  end

  def update_task_status(%Task{} = task, status) do
    task |> Ecto.Changeset.change(status: status) |> Repo.update()
  end

  @doc "The latest revision of every task key in `run`, oldest key first."
  def latest_tasks(%Run{} = run) do
    run
    |> list_tasks()
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, revisions} -> Enum.max_by(revisions, & &1.revision) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  What a worker should know about `task`'s dependencies (plan 7.5): for each key in
  `depends_on`, its accepted revision's title, the worker's summary and the files it changed.
  """
  def dependency_context(%Task{depends_on: []}), do: []

  def dependency_context(%Task{run_id: run_id, depends_on: keys}) do
    latest = %Run{id: run_id} |> latest_tasks() |> Map.new(&{&1.key, &1})

    for key <- keys, task = latest[key], task.status == :accepted do
      attempt =
        Repo.one(
          from a in Attempt,
            where: a.task_id == ^task.id and a.status == :accepted,
            order_by: [desc: a.id],
            limit: 1
        )

      %{
        key: key,
        title: task.title,
        summary: attempt && attempt.result && attempt.result["summary"],
        writes: if(attempt, do: Enum.map(attempt.actual_writes, & &1["path"]), else: [])
      }
    end
  end

  ## Deliveries (plan 7.6)

  @doc "Records that `task` ended in `status` (once per task; later calls change nothing)."
  def receive_delivery(%Task{id: task_id, run_id: run_id}, status) do
    %Delivery{run_id: run_id, task_id: task_id, status: status}
    |> Repo.insert(on_conflict: :nothing, conflict_target: :task_id)
  end

  @doc "Deliveries of `run` not yet sent to the planner, with their tasks, oldest first."
  def pending_deliveries(%Run{id: run_id}) do
    Repo.all(
      from d in Delivery,
        where: d.run_id == ^run_id and is_nil(d.delivered_at),
        order_by: [d.inserted_at, d.id],
        preload: :task
    )
  end

  def delivered_task_ids(%Run{id: run_id}) do
    Repo.all(from d in Delivery, where: d.run_id == ^run_id, select: d.task_id)
  end

  def mark_delivered(deliveries) do
    ids = Enum.map(deliveries, & &1.id)

    from(d in Delivery, where: d.id in ^ids)
    |> Repo.update_all(set: [delivered_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])
  end

  @doc "The latest attempt of `task`, or nil."
  def latest_attempt(%Task{id: task_id}) do
    Repo.one(from a in Attempt, where: a.task_id == ^task_id, order_by: [desc: a.id], limit: 1)
  end

  ## Attempts

  @doc "Creates the next attempt of `task` (numbered from 1) in `:queued`."
  def create_attempt(%Task{id: task_id}, attrs) do
    Repo.transaction(fn ->
      number =
        Repo.one(from a in Attempt, where: a.task_id == ^task_id, select: count(a.id)) + 1

      %Attempt{task_id: task_id, number: number}
      |> Attempt.create_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, attempt} -> attempt
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def get_attempt!(id), do: Repo.get!(Attempt, id)

  @doc "Attempts that may still have a live pi process or be changing files (optionally of one workspace)."
  def list_in_flight_attempts do
    Repo.all(from a in Attempt, where: a.status in ^Attempt.in_flight_statuses(), order_by: a.id)
  end

  def list_in_flight_attempts(%Workspace{id: workspace_id}) do
    Repo.all(
      from a in Attempt,
        join: t in assoc(a, :task),
        join: r in assoc(t, :run),
        where: r.workspace_id == ^workspace_id and a.status in ^Attempt.in_flight_statuses(),
        order_by: a.id
    )
  end

  @doc "The run and workspace an attempt belongs to."
  def attempt_context(%Attempt{task_id: task_id}) do
    task = Repo.get!(Task, task_id)
    run = Repo.get!(Run, task.run_id)
    %{task: task, run: run, workspace: Repo.get!(Workspace, run.workspace_id)}
  end

  @doc """
  Adds spend to a run: `confirmed` USD, and `unknown` usage entries that came without a cost
  (never counted as 0). Atomic in the database; returns the updated run.
  """
  def add_spend(%Run{id: id}, confirmed, unknown) do
    from(r in Run, where: r.id == ^id)
    |> Repo.update_all(
      inc: [spent_usd: confirmed, spent_unknown: unknown],
      set: [updated_at: DateTime.utc_now()]
    )

    Repo.get!(Run, id)
  end

  @doc "True when the run has a budget and its confirmed spend reached it."
  def budget_exhausted?(%Run{budget_usd: nil}), do: false
  def budget_exhausted?(%Run{budget_usd: budget, spent_usd: spent}), do: spent >= budget

  @doc "Sets attempt fields without a status change (e.g. the verify command's process group)."
  def update_attempt_fields(%Attempt{} = attempt, attrs) do
    changeset = Attempt.fields_changeset(attempt, attrs)

    from(a in Attempt, where: a.id == ^attempt.id)
    |> Repo.update_all(
      set: Map.to_list(Map.put(changeset.changes, :updated_at, DateTime.utc_now()))
    )

    Repo.get!(Attempt, attempt.id)
  end

  @doc "Adds `flag` to an attempt without changing its status (e.g. \"kept\")."
  def add_attempt_flag(%Attempt{id: id}, flag) when is_binary(flag) do
    from(a in Attempt, where: a.id == ^id and ^flag not in a.flags)
    |> Repo.update_all(push: [flags: flag], set: [updated_at: DateTime.utc_now()])

    {:ok, Repo.get!(Attempt, id)}
  end

  @doc "The attempts of a run with their tasks, oldest first (for display)."
  def list_run_attempts_with_tasks(%Run{id: run_id}) do
    Repo.all(
      from a in Attempt,
        join: t in assoc(a, :task),
        where: t.run_id == ^run_id,
        order_by: [asc: a.inserted_at, asc: a.id],
        preload: [task: t]
    )
  end

  @doc "The attempts of a run, newest first."
  def list_run_attempts(%Run{id: run_id}) do
    Repo.all(
      from a in Attempt,
        join: t in assoc(a, :task),
        where: t.run_id == ^run_id,
        order_by: [desc: a.inserted_at, desc: a.id]
    )
  end

  @doc """
  Moves `attempt` to status `to`, setting `attrs`. Returns `{:ok, attempt}`,
  `{:error, {:illegal, from, to}}` if the move isn't allowed, `{:error, :stale}` if the stored
  status is no longer `attempt.status` (someone else moved it), or `{:error, changeset}`.
  """
  def transition_attempt(%Attempt{id: id, status: from} = attempt, to, attrs \\ %{}) do
    changeset = Attempt.transition_changeset(attempt, to, attrs)

    cond do
      not Attempt.allowed?(from, to) ->
        {:error, {:illegal, from, to}}

      not changeset.valid? ->
        {:error, changeset}

      true ->
        changes = Map.put(changeset.changes, :updated_at, DateTime.utc_now())

        case Repo.update_all(from(a in Attempt, where: a.id == ^id and a.status == ^from),
               set: Map.to_list(changes)
             ) do
          {1, _} -> {:ok, Repo.get!(Attempt, id)}
          {0, _} -> {:error, :stale}
        end
    end
  end
end
