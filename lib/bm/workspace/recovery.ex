defmodule Bm.Workspace.Recovery do
  @moduledoc """
  Minimal recovery (docs/ARCHITECTURE.md §11). An attempt still recorded as in flight
  (`admitted` … `verifying`) after a BEAM restart, or after its coordinator died, has nobody
  looking after it. For each one:

    1. stop its pi adapter if it still runs, and end its process groups (pi's, every bash
       command's, the verify command's) — only if they were recorded in this boot, since after a
       reboot the ids may belong to other programs;
    2. snapshot the workspace and compare with the attempt's `tree_before`;
    3. no change → `failed` ("interrupted", safe to run again); any change →
       `needs_reconciliation` with its write set, and the run is paused until the user decides
       (Keep or Revert). An attempt that may have changed files is never retried automatically.

  A **goal run** whose planner is gone (plan 7.9) is paused with the reason "planner lost": its
  pi session is stopped, its recorded process groups are ended (same boot only), and the user
  chooses Resume planning or Finish on the run page. The planner is never restarted by itself.

  Runs at application start (`run/0`) and when a workspace coordinator starts
  (`recover_workspace/1`).
  """

  require Logger

  alias Bm.Runs
  alias Bm.Runs.Attempt
  alias Bm.Workspace.Git

  @doc "Recovers every in-flight attempt. Returns the recovered attempts."
  def run do
    attempts = Runs.list_in_flight_attempts() |> Enum.map(&recover/1)
    Enum.each(Runs.list_active_goal_runs(), &recover_planner/1)
    attempts
  end

  @doc "Recovers the in-flight attempts of one workspace."
  def recover_workspace(workspace) do
    attempts = Runs.list_in_flight_attempts(workspace) |> Enum.map(&recover/1)

    Runs.list_active_goal_runs()
    |> Enum.filter(&(&1.workspace_id == workspace.id))
    |> Enum.each(&recover_planner/1)

    attempts
  end

  @doc "Pauses a goal run whose planner process is gone (plan 7.9)."
  def recover_planner(run) do
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

      {:ok, _run} =
        Runs.pause_run(run, "planner lost: BM stopped while this run was planning or running")

      Logger.warning("paused goal run #{run.id}: planner lost")
    end
  end

  @doc "Recovers one attempt; returns it in its new status."
  def recover(%Attempt{} = attempt) do
    %{run: run, workspace: workspace} = Runs.attempt_context(attempt)

    Bm.Pi.stop("attempt-#{attempt.id}")
    end_process_groups(attempt)

    {status, attrs, pause?} = outcome(workspace.path, attempt)

    {:ok, attempt} =
      case Runs.transition_attempt(attempt, status, attrs) do
        {:ok, attempt} ->
          {:ok, attempt}

        # Someone moved it meanwhile (it was not orphaned after all): leave it alone.
        {:error, :stale} ->
          {:ok, Runs.get_attempt!(attempt.id)}
      end

    task = Runs.get_task!(attempt.task_id)
    Runs.update_task_status(task, :failed)
    if pause? and run.status == :active, do: Runs.pause_run(run)

    Logger.warning("recovered attempt #{attempt.id} as #{attempt.status}")
    attempt
  end

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
