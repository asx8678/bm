defmodule Bm.Workspace.Recovery do
  @moduledoc """
  Minimal recovery (docs/ARCHITECTURE.md §11). An attempt still recorded as in flight
  (`admitted` … `verifying`) after a BEAM restart, or after its coordinator died, has nobody
  looking after it. For each one:

    1. stop its pi adapter if it still runs, and end its process groups (pi's, every bash
       command's, the verify command's) — only if they were recorded in this boot, since after a
       reboot the ids may belong to other programs;
    2. snapshot the workspace and compare with the attempt's `tree_before`;
    3. no change → `failed` ("interrupted", safe to run again; in a goal run its task is queued
       again, plan 21.1); any change → `needs_reconciliation` with its write set, and the run is
       paused until the user decides (Keep or Revert). An attempt that may have changed files is
       never retried or reverted automatically.

  A **goal run** whose planner is gone (plan 7.9) is paused with the reason "planner lost": its
  pi session is stopped and its recorded process groups are ended (same boot only). After an
  application restart it then resumes planning by itself (plan 21.2, decision D27) if automatic
  resume is on, its lane is free, its budget is not spent and it resumed this way fewer than 3
  times; otherwise the reason says why, and the user chooses Resume planning or Finish on the run
  page. When only a coordinator restarts, the run just pauses.

  Runs at application start (`run/0`, before the Endpoint serves) and when a workspace coordinator starts
  (`recover_workspace/1`).
  """

  require Logger

  alias Bm.Runs
  alias Bm.Runs.Attempt
  alias Bm.Workspace.{Coordinator, Git}

  @doc """
  Recovers every in-flight attempt, then every goal run that was active when BM stopped: its
  planner is gone, so the run resumes by itself when it can (plan 21.2), else it pauses. Runs at
  application start. Returns the recovered attempts.
  """
  def run do
    # Taken first: recovering an attempt that changed files pauses its run.
    runs = Runs.list_active_goal_runs()
    attempts = Runs.list_in_flight_attempts() |> Enum.map(&recover/1)
    Enum.each(runs, &recover_planner(&1, auto_resume: true))
    attempts
  end

  @doc """
  Runs `run/0` inside the application's start-up, before the Endpoint serves, and returns
  `:ignore`. A failure is logged and doesn't stop BM from starting.
  """
  def start_link(recover? \\ true) do
    if recover? do
      try do
        run()
      rescue
        error ->
          Logger.error(
            "recovery at start failed: " <> Exception.format(:error, error, __STACKTRACE__)
          )
      catch
        kind, reason -> Logger.error("recovery at start failed: #{inspect({kind, reason})}")
      end
    end

    :ignore
  end

  @doc "Recovers the in-flight attempts of one workspace."
  def recover_workspace(workspace) do
    attempts = Runs.list_in_flight_attempts(workspace) |> Enum.map(&recover/1)

    Runs.list_active_goal_runs()
    |> Enum.filter(&(&1.workspace_id == workspace.id))
    |> Enum.each(&recover_planner/1)

    attempts
  end

  @doc """
  Pauses a goal run whose planner process is gone (plan 7.9). With `auto_resume: true` (after a
  restart) it then resumes planning if nothing stands in the way (plan 21.2).
  """
  def recover_planner(run, opts \\ []) do
    if Bm.Workspace.Planner.whereis(run.id) == nil do
      planner = run.planner || %{}
      if agent_id = planner["agent_id"], do: Bm.Pi.stop(agent_id)

      if planner["boot_id"] != nil and planner["boot_id"] == Bm.Proc.boot_id() do
        groups =
          [planner["pgid"]]
          |> Enum.reject(&is_nil/1)
          |> Kernel.++(
            if planner["pgid_file"], do: Bm.Proc.read_pgid_file(planner["pgid_file"]), else: []
          )

        Bm.Proc.terminate_groups(Bm.Proc.live_groups(groups))
      end

      lost = "planner lost: BM stopped while this run was planning or running"
      # Reloaded: recovering an interrupted attempt that changed files may have paused it.
      run = %{Runs.get_run!(run.id) | workspace: run.workspace}

      paused =
        case run.status do
          :active -> Runs.pause_run(run, lost)
          :paused -> Runs.update_run(run, %{status_reason: lost})
          _ended -> :ended
        end

      with {:ok, run} <- paused do
        Logger.warning("paused goal run #{run.id}: planner lost")
        if opts[:auto_resume], do: auto_resume(run, lost)
      end
    end
  end

  @max_auto_resumes 3

  # After a restart, planning resumes in a new session unless something needs the user; the
  # run then stays paused and its reason says why (plan 21.2). Resumes are counted so that a
  # crash loop ends after @max_auto_resumes.
  defp auto_resume(run, lost) do
    root = run.workspace.path
    resumes = run.planner["auto_resumes"] || 0

    blocker =
      cond do
        not Application.get_env(:bm, :auto_resume, true) -> "automatic resume is turned off"
        Runs.budget_exhausted?(run) -> "the run's budget is spent"
        resumes >= @max_auto_resumes -> "it already resumed by itself #{resumes} times"
        true -> lane_blocker(root)
      end

    if blocker do
      Runs.update_run(run, %{status_reason: "#{lost}; not resumed by itself: #{blocker}"})
      Logger.warning("goal run #{run.id} not resumed: #{blocker}")
    else
      resume(run, root, resumes + 1, lost)
    end
  end

  # The coordinator's own view: a held lane means changes wait for the user's decision.
  defp lane_blocker(root) do
    with {:ok, _pid} <- Coordinator.ensure_started(root),
         %{lane: :free, phase: nil} <- Coordinator.state(root) do
      nil
    else
      %{lane: {:held, _}} -> "changes wait for your decision (Keep or Revert)"
      %{} -> "the workspace is busy"
      {:error, reason} -> "the workspace did not start: #{inspect(reason)}"
    end
  end

  defp resume(run, root, count, lost) do
    # Reloaded: the planner map is written back whole.
    run = %{Runs.get_run!(run.id) | workspace: run.workspace}

    note = %{
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "kind" => "note",
      "text" =>
        "BM restarted while this run was active; planning resumed by itself " <>
          "(#{count} of #{@max_auto_resumes})."
    }

    planner =
      run.planner
      |> Map.put("auto_resumes", count)
      |> Map.put("log", Enum.take((run.planner["log"] || []) ++ [note], -60))

    {:ok, run} = Runs.update_run(run, %{planner: planner})

    case Coordinator.resume_planning(root, run.id) do
      {:ok, _run} ->
        Logger.warning("goal run #{run.id} resumed after a restart (#{count})")

      {:error, reason} ->
        run = Runs.get_run!(run.id)
        Runs.update_run(run, %{status_reason: "#{lost}; resuming failed: #{inspect(reason)}"})
    end
  end

  @doc "Recovers one attempt; returns it in its new status."
  def recover(%Attempt{} = attempt) do
    %{run: run, workspace: workspace} = Runs.attempt_context(attempt)

    Bm.Pi.stop("attempt-#{attempt.id}")
    end_process_groups(attempt)

    {status, attrs, pause?} = outcome(workspace.path, attempt)

    case Runs.transition_attempt(attempt, status, attrs) do
      {:ok, attempt} ->
        task = Runs.get_task!(attempt.task_id)
        Runs.update_task_status(task, task_status(run, status))
        if pause? and run.status == :active, do: Runs.pause_run(run)

        Logger.warning("recovered attempt #{attempt.id} as #{attempt.status}")
        attempt

      # Someone moved it meanwhile (it was not orphaned after all): leave it alone.
      {:error, :stale} ->
        Runs.get_attempt!(attempt.id)
    end
  end

  # In a goal run, an attempt interrupted before it changed anything did not fail: its task
  # waits to run again, without using up its one re-plan (plan 21.1). A single-task run has
  # nothing that would run it again, so there the task fails and the user re-runs it.
  defp task_status(%{planner: %{}}, :failed), do: :queued
  defp task_status(_run, _status), do: :failed

  defp end_process_groups(%Attempt{boot_id: boot_id} = attempt) do
    if boot_id != nil and boot_id == Bm.Proc.boot_id() do
      groups =
        [attempt.pgid, verify_pgid(attempt)]
        |> Enum.reject(&is_nil/1)
        |> Kernel.++(pgid_file_groups(attempt))

      Bm.Proc.terminate_groups(Bm.Proc.live_groups(groups))
    end
  end

  defp verify_pgid(%Attempt{verify: %{"pgid" => pgid}}), do: pgid
  defp verify_pgid(_attempt), do: nil

  defp pgid_file_groups(%Attempt{pgid_file: nil}), do: []
  defp pgid_file_groups(%Attempt{pgid_file: file}), do: Bm.Proc.read_pgid_file(file)

  defp outcome(root, %Attempt{tree_before: tree_before}) when is_binary(tree_before) do
    with {:ok, tree} <- Git.snapshot(root),
         {:ok, entries} <- Git.diff(root, tree_before, tree) do
      writes = for e <- entries, do: %{"path" => e.path, "status" => Atom.to_string(e.status)}

      if writes == [] do
        {:failed, %{tree_after: tree, error: "interrupted (no changes; safe to run again)"},
         false}
      else
        {:needs_reconciliation,
         %{
           tree_after: tree,
           actual_writes: writes,
           error: "interrupted after changing files; keep or revert them"
         }, true}
      end
    else
      error ->
        {:needs_reconciliation, %{error: "interrupted; snapshot failed: #{inspect(error)}"}, true}
    end
  end

  defp outcome(_root, _attempt),
    do: {:failed, %{error: "interrupted before it started"}, false}
end
