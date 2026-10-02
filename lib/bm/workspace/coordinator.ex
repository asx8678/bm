defmodule Bm.Workspace.Coordinator do
  @moduledoc """
  One process per checkout (docs/ARCHITECTURE.md §7). It owns the workspace's **mutation lane**:
  at most one attempt runs at a time (decision D5), and the lane stays **held** after an attempt
  that left changes BM could not accept, until the user chooses Keep (or Revert, phase 5).

  An attempt goes through these phases:

      :baseline   (first attempt of a run) the verify command runs on the untouched checkout,
                  so a checkout that already fails is told apart from one the worker broke
      :starting   pi is started with the task's profile and checked (fail closed)
      :running    the worker runs; its bm:authorize requests are answered by `Bm.Policy`,
                  its bm:submit_result is persisted (fenced by the attempt and pi session)
      :settling   pi has settled; wait until no process is left in its groups (decision D18)
      :stopping   pi is stopped (graceful, then group kill)
      (attribute) snapshot → the attempt's actual write set, checked against the user-owned
                  files and the declared set
      :verifying  the workspace's verify command runs as its own process group, with a timeout
      (accept)    checkpoint under refs/bm/runs/<run>/<n>; the lane is free again

  Starting and stopping pi and running verification happen in supervised tasks, so the
  coordinator keeps answering the worker and can always cancel. Events are broadcast on
  `topic/1` as `{:workspace, root, event}`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Bm.Pi.Profile
  alias Bm.Runs
  alias Bm.Runs.Attempt
  alias Bm.Workspace.Git

  @defaults [
    settle_interval: 200,
    settle_timeout: 10_000,
    verify_timeout: 600_000,
    # Limits per attempt (5.2): total time running, and time without any pi event while no
    # tool runs.
    max_duration: 20 * 60_000,
    stall_timeout: 3 * 60_000,
    # Refined limits (plan 11.5): one tool call running this long cancels the attempt; the Nth
    # identical guarded call is refused, the Mth cancels the attempt.
    tool_timeout: 10 * 60_000,
    # Another extension's question to the user waits this long, then is declined (plan 24.1).
    approval_timeout: 2 * 60_000,
    # Supervisor (plan 25.1): a writing attempt this old with this many tool calls and no changed
    # file is told once, and cancelled if it still changes nothing after as long again.
    progress_after: 6 * 60_000,
    progress_calls: 30,
    repeat_refuse: 4,
    repeat_cancel: 6,
    # The review prompt (plan 14.1); tests or scripts can replace it.
    review_prompt: &Bm.Prompts.reviewer/4,
    prompt: &Bm.Prompts.worker/2
  ]

  @no_planner_answer %{
    "ok" => true,
    "answer" =>
      "The planner is not available. Decide yourself from the task and the repository, or " <>
        "submit_result with status blocked and say what is unclear."
  }
  @ask_timeout 180_000

  ## API

  @doc """
  Starts the coordinator for the checkout at `path` (its top level) unless it runs already.
  Options (first start only): `:settle_interval`, `:settle_timeout`, `:verify_timeout`,
  `:max_duration`, `:stall_timeout` (ms) and `:prompt` (a function from the task to the worker
  prompt).
  """
  def ensure_started(path, opts \\ []) do
    with {:ok, root} <- Runs.canonical_path(path),
         :ok <- Git.check_root(root),
         {:ok, workspace} <- Runs.ensure_workspace(root) do
      spec = {__MODULE__, Keyword.merge(opts, root: root, workspace: workspace)}

      case DynamicSupervisor.start_child(Bm.Workspace.Supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        error -> error
      end
    end
  end

  @doc """
  Runs one task. `attrs`: task fields (`:title`, `:goal`, `:mutates`, `:writes`, `:done_when`,
  optional `:key`), optional `:verify_command` (saved on the workspace), and for a new run
  `:run_goal` and `:budget_usd`. With `%{task_id: id}` it runs a queued task of the current run
  instead (the planner's scheduler, plan 7.4).
  Returns `{:ok, attempt}` once admitted; the attempt continues asynchronously.
  """
  def run_task(path, attrs, run_id \\ nil),
    do: call(path, fenced({:run_task, Map.new(attrs)}, run_id))

  @doc """
  Starts a goal run (milestone C): a new run with planning open, and its planner
  (`Bm.Workspace.Planner`), which proposes tasks and has them run here one at a time. `attrs`:
  `:goal`, optional `:verify_command` (saved on the workspace) and `:budget_usd`.
  `planner_opts` go to the planner (tests pass a scripted prompt and limits).
  Returns `{:ok, run}`; refused while the workspace has an unfinished run or a held lane.
  """
  def start_goal(path, attrs, planner_opts \\ []),
    do: call(path, {:start_goal, Map.new(attrs), planner_opts})

  @doc """
  Ends the goal run `run_id` as `:done`, `:failed` or `:cancelled` with `reason`; queued tasks
  are cancelled. Refused while an attempt runs or waits for the user's decision.
  """
  def end_run(path, run_id, status, reason),
    do: call(path, {:end_run, run_id, status, reason})

  @doc """
  Answers the worker's pending approval `dialog_id` (plan 24.1) with pi's answer fields:
  `%{"confirmed" => boolean}`, `%{"value" => text}` or `%{"cancelled" => true}`.
  """
  def answer_approval(path, dialog_id, reply),
    do: call(path, {:answer_approval, dialog_id, reply})

  @doc "Pauses the run `run_id` with `reason` (the planner lost or changed files)."
  def pause_run(path, run_id, reason), do: call(path, {:pause_run, run_id, reason})

  @doc """
  The user pauses the active goal run `run_id` (plan 23.1): its planner stops (a running
  attempt finishes first) and the run waits for Resume planning or Finish.
  """
  def pause_by_user(path, run_id), do: call(path, {:pause_by_user, run_id})

  @doc "Resumes planning of the paused goal run `run_id` in a new planner session."
  def resume_planning(path, run_id, planner_opts \\ []),
    do: call(path, {:resume_planning, run_id, planner_opts})

  @doc """
  Reverts every change a finished run left in the workspace (plan 11.4): one all-or-nothing
  conditional restore over the union of the write sets of its attempts whose changes stayed
  (accepted, or kept by the user), from the earliest one's `tree_before` to the latest one's
  `tree_after`. `{:error, {:changed_since, paths}}` changes nothing. Refused while the workspace
  has an unfinished run, and for a run already reverted.
  """
  def revert_run(path, run_id), do: call(path, {:revert_run, run_id})

  @doc """
  Commits the changes a finished run left (plan 15.1, D26), only on the user's request: the
  files of its attempts whose changes stayed, as the run left them, on the user's current branch
  with the run's goal as the message (`Git.commit_paths/3`). Refused if any of those files
  changed since the run (`{:changed_since, paths}`), if the user staged changes in them, while
  the workspace has an unfinished run, or for a reverted or already committed run.
  """
  def commit_run(path, run_id), do: call(path, {:commit_run, run_id})

  @doc """
  Undoes one task of a finished run (plan 13.3): a conditional restore of its accepted attempt's
  write set to `tree_before`. Refused if a later change touched those files
  (`{:changed_since, paths}`, nothing touched), if an accepted task depends on it
  (`{:dependents, keys}`), while the workspace has an unfinished run, or for an unfinished run.
  """
  def revert_task(path, task_id), do: call(path, {:revert_task, task_id})

  @doc "Lane, phase, run and current attempt."
  def state(path), do: call(path, :state)

  @doc "Cancels the running attempt. Changes it made stay and hold the lane."
  def cancel(path, run_id \\ nil), do: call(path, fenced(:cancel, run_id))

  @doc "Accepts the held attempt's changes as they are (recorded as unverified) and frees the lane."
  def keep(path, run_id \\ nil), do: call(path, fenced(:keep, run_id))

  @doc """
  Reverts the run's latest attempt (held or not): its files go back to `tree_before`, only if
  they still hold what the attempt left. `{:error, {:changed_since, paths}}` changes nothing.
  """
  def revert(path, run_id \\ nil), do: call(path, fenced(:revert, run_id))

  @doc """
  Finishes the workspace's run (`:done`), which releases the workspace: the next task starts a
  new run with a fresh baseline of the user's files. Refused while an attempt runs or the lane
  is held.
  """
  def finish_run(path, run_id \\ nil), do: call(path, fenced(:finish_run, run_id))

  # With a run id (the run page, the API), the action applies only while that run is the
  # workspace's unfinished one: a page left open on a finished run must not stop, keep, revert
  # or finish the next run, or add a task to it (plan 36.12).
  defp fenced(message, nil), do: message
  defp fenced(message, run_id), do: {:for_run, run_id, message}

  @doc "Stops the coordinator and its worker."
  def stop(path) do
    with {:ok, root} <- Runs.canonical_path(path),
         [{pid, _}] <- Registry.lookup(Bm.Workspace.Registry, root) do
      DynamicSupervisor.terminate_child(Bm.Workspace.Supervisor, pid)
    else
      _ -> :ok
    end
  end

  def topic(root), do: "workspace:" <> root

  def subscribe(path) do
    with {:ok, root} <- Runs.canonical_path(path),
         do: Phoenix.PubSub.subscribe(Bm.PubSub, topic(root))
  end

  defp call(path, message) do
    with {:ok, root} <- Runs.canonical_path(path) do
      case Registry.lookup(Bm.Workspace.Registry, root) do
        [{pid, _}] -> GenServer.call(pid, message, 30_000)
        [] -> {:error, :not_started}
      end
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:root]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Bm.Workspace.Registry, Keyword.fetch!(opts, :root)}}
    )
  end

  ## State

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      root: Keyword.fetch!(opts, :root),
      workspace: Keyword.fetch!(opts, :workspace),
      config: Map.new(Keyword.merge(@defaults, Keyword.take(opts, Keyword.keys(@defaults)))),
      run: nil,
      lane: :free,
      phase: nil,
      attempt: nil,
      task: nil,
      agent_id: nil,
      agent_ref: nil,
      assignment: nil,
      seen_running?: false,
      cancel?: false,
      flags: [],
      settle_deadline: nil,
      # The one blocking job in progress: {task ref, kind}.
      job: nil,
      verify_pgid: nil,
      # Why BM cancels the attempt (budget, stall, max_duration); nil when the user cancels.
      cancel_reason: nil,
      # The worker's spend already added to the run, its running tool, and time bookkeeping.
      spend_seen: %{confirmed: 0.0, unknown: 0},
      tool: nil,
      running_since: nil,
      last_event_at: nil,
      # When the running tool call started, and identical guarded calls seen (plan 11.5).
      tool_since: nil,
      repeats: %{},
      # Paths this attempt was allowed to edit/write, and whether it ran bash (plan 13.2).
      touched: MapSet.new(),
      bash_ran?: false,
      # The verification result and changes waiting for the reviewer (plan 14.1).
      pending_review: nil,
      # Workers' questions waiting for the planner (plan 12.2): task ref => {agent_id, request}.
      asks: %{},
      # Monitor of the goal run's planner process.
      planner_ref: nil,
      # Other extensions' questions to the user from the running worker (plan 24.1).
      approvals: %{},
      # Supervisor (plan 25.1): the attempt's tool calls, files it was told about, and
      # nil | {:steered, at} | :changed for the no-progress check.
      tool_calls: 0,
      steered: MapSet.new(),
      progress: nil
    }

    # Attempts left in flight by an earlier coordinator have nobody looking after them.
    Bm.Workspace.Recovery.recover_workspace(state.workspace)
    {:ok, restore_lane(state)}
  end

  # After a coordinator restart, a held attempt of the unfinished run still holds the lane.
  defp restore_lane(state) do
    case Runs.get_unfinished_run(state.workspace) do
      nil ->
        state

      run ->
        held =
          run
          |> Runs.list_run_attempts()
          |> Enum.find(fn attempt ->
            attempt.status == :held or
              (attempt.status in [:failed, :cancelled, :needs_reconciliation] and holds?(attempt))
          end)

        planner = run.planner && Bm.Workspace.Planner.whereis(run.id)
        planner_ref = if planner, do: Process.monitor(planner)

        %{
          state
          | run: run,
            lane: if(held, do: {:held, held.id}, else: :free),
            planner_ref: planner_ref
        }
    end
  end

  # Changes BM could not accept wait for the user; so does every interrupted attempt.
  defp holds?(%Attempt{status: :needs_reconciliation, flags: flags}), do: "kept" not in flags

  defp holds?(%Attempt{actual_writes: writes, flags: flags}),
    do: writes != [] and "kept" not in flags

  ## Calls

  @impl true
  def handle_call({:for_run, run_id, message}, from, %{run: %{id: run_id}} = state),
    do: handle_call(message, from, state)

  def handle_call({:for_run, _run_id, _message}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call(:state, _from, state) do
    reply = %{
      lane: state.lane,
      phase: state.phase,
      run_id: state.run && state.run.id,
      attempt_id: state.attempt && state.attempt.id,
      approvals: approval_list(state)
    }

    {:reply, reply, state}
  end

  # Fields added to the state over time. A coordinator started by older code (the dev server's
  # code reloader keeps running processes) gets them before it admits new work, instead of
  # crashing on a missing key (seen twice in the Phase 12–14 trials).
  @late_fields %{
    tool_since: nil,
    repeats: %{},
    asks: %{},
    touched: MapSet.new(),
    bash_ran?: false,
    pending_review: nil,
    planner_ref: nil,
    approvals: %{},
    tool_calls: 0,
    steered: MapSet.new(),
    progress: nil
  }

  # Checked on the newest late field: a state without it lacks some of the others too.
  def handle_call(message, from, state)
      when is_tuple(message) and elem(message, 0) in [:run_task, :start_goal] and
             not is_map_key(state, :progress) do
    handle_call(message, from, Map.merge(@late_fields, state))
  end

  def handle_call({:run_task, _attrs}, _from, %{lane: lane} = state) when lane != :free,
    do: {:reply, {:error, :lane_busy}, state}

  def handle_call({:run_task, %{task_id: _}}, _from, %{run: nil} = state),
    do: {:reply, {:error, :run_not_active}, state}

  # A goal run's tasks come from its planner only.
  def handle_call({:run_task, attrs}, _from, %{run: %{planner: %{}}} = state)
      when not is_map_key(attrs, :task_id),
      do: {:reply, {:error, :goal_run_active}, state}

  def handle_call({:start_goal, _attrs, _opts}, _from, %{lane: lane} = state) when lane != :free,
    do: {:reply, {:error, :lane_busy}, state}

  def handle_call({:start_goal, _attrs, _opts}, _from, %{run: %{}} = state),
    do: {:reply, {:error, :workspace_busy}, state}

  def handle_call({:start_goal, attrs, opts}, _from, state) do
    with {:ok, workspace} <- maybe_set_verify_command(state.workspace, attrs),
         :ok <- if(workspace.verify_command, do: :ok, else: {:error, :no_verify_command}),
         {:ok, baseline} <- Git.baseline(state.root),
         {:ok, run} <-
           Runs.start_run(workspace, %{
             goal: attrs[:goal],
             budget_usd: attrs[:budget_usd],
             plan_open: true,
             planner: %{"session" => 0, "waves" => 1, "log" => []},
             baseline: %{
               "head" => baseline.head,
               "tree" => baseline.tree,
               "user_owned" => baseline.user_owned
             }
           }),
         {:ok, pid} <- start_planner_or_fail(state, run, opts) do
      state = %{state | workspace: workspace, run: run, planner_ref: Process.monitor(pid)}
      broadcast_run(state, run)
      {:reply, {:ok, run}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:end_run, run_id, status, reason}, _from, %{run: %{id: run_id}} = state) do
    run = Runs.get_run!(run_id)

    cond do
      # Only the run's planner ends it, and a paused run's planner is stopping (the user paused
      # it, or it paused itself): what it still sends on its way out must not end the run.
      run.status == :paused ->
        {:reply, {:error, :run_paused}, state}

      state.phase == nil and state.lane == :free ->
        for task <- Runs.latest_tasks(run), task.status in [:queued, :running] do
          Runs.update_task_status(task, :cancelled)
        end

        run = stored(Runs.finish_run(run, status, reason), run)
        if state.planner_ref, do: Process.demonitor(state.planner_ref, [:flush])
        broadcast_run(state, run)
        state = prune_checkpoints(state)
        {:reply, {:ok, run}, %{state | run: nil, attempt: nil, task: nil, planner_ref: nil}}

      true ->
        {:reply, {:error, :lane_busy}, state}
    end
  end

  def handle_call({:end_run, _run_id, _status, _reason}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call({:pause_run, run_id, reason}, _from, %{run: %{id: run_id}} = state) do
    case Runs.get_run!(run_id) do
      %{status: :active} = run ->
        run = stored(Runs.pause_run(run, reason), run)
        broadcast_run(state, run)
        {:reply, {:ok, run}, %{state | run: run}}

      run ->
        {:reply, {:ok, run}, state}
    end
  end

  def handle_call({:pause_run, _run_id, _reason}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call({:answer_approval, dialog_id, reply}, _from, state) do
    case Map.get(state, :approvals, %{}) do
      %{^dialog_id => _approval} -> {:reply, :ok, reply_approval(state, dialog_id, reply)}
      _other -> {:reply, {:error, :no_such_approval}, state}
    end
  end

  def handle_call({:pause_by_user, run_id}, _from, %{run: %{id: run_id}} = state) do
    case Runs.get_run!(run_id) do
      %{status: :active, planner: %{}} = run ->
        # No longer watched: its exit is not a surprise to report. Stopped asynchronously, as in
        # finish_run: the planner may be calling this process right now, and stopping it from
        # here would wait out its shutdown timeout and then kill it before it ends its pi
        # session. The run is paused first, so whatever it asks meanwhile is refused.
        if state.planner_ref, do: Process.demonitor(state.planner_ref, [:flush])
        run = stored(Runs.pause_run(run, "paused by the user"), run)
        Task.start(fn -> Bm.Workspace.Planner.stop(run_id) end)
        broadcast_run(state, run)
        {:reply, {:ok, run}, %{state | run: run, planner_ref: nil}}

      _run ->
        {:reply, {:error, :not_pausable}, state}
    end
  end

  def handle_call({:pause_by_user, _run_id}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call({:resume_planning, run_id, opts}, _from, %{run: %{id: run_id}} = state) do
    run = Runs.get_run!(run_id)

    cond do
      run.status != :paused or run.planner == nil ->
        {:reply, {:error, :not_resumable}, state}

      state.phase != nil or state.lane != :free ->
        {:reply, {:error, :lane_busy}, state}

      Bm.Workspace.Planner.whereis(run_id) != nil ->
        {:reply, {:error, :planner_stopping}, state}

      true ->
        run = stored(Runs.resume_run(run), run)

        case start_planner(state, run, Keyword.put(opts, :resume, true)) do
          {:ok, pid} ->
            broadcast_run(state, run)
            {:reply, {:ok, run}, %{state | run: run, planner_ref: Process.monitor(pid)}}

          {:error, reason} ->
            run =
              stored(Runs.pause_run(run, "the planner did not start: #{inspect(reason)}"), run)

            {:reply, {:error, reason}, %{state | run: run}}
        end
    end
  end

  def handle_call({:resume_planning, _run_id, _opts}, _from, state),
    do: {:reply, {:error, :not_resumable}, state}

  def handle_call({:commit_run, _run_id}, _from, %{run: %{}} = state),
    do: {:reply, {:error, :workspace_busy}, state}

  def handle_call({:commit_run, run_id}, _from, state) do
    run = Runs.get_run!(run_id)

    reply =
      cond do
        run.workspace_id != state.workspace.id -> {:error, :run_not_in_workspace}
        run.status in [:active, :paused] -> {:error, :run_not_finished}
        run.reverted_at != nil -> {:error, :already_reverted}
        run.commit_sha != nil -> {:error, {:already_committed, run.commit_sha}}
        true -> do_commit_run(state, run)
      end

    {:reply, reply, state}
  end

  def handle_call({:revert_task, _task_id}, _from, %{phase: phase} = state) when phase != nil,
    do: {:reply, {:error, :attempt_running}, state}

  def handle_call({:revert_task, task_id}, _from, state) do
    task = Runs.get_task!(task_id)
    run = Runs.get_run!(task.run_id)

    cond do
      run.workspace_id != state.workspace.id ->
        {:reply, {:error, :run_not_in_workspace}, state}

      run.status in [:active, :paused] ->
        revert_task_in_run(state, run, task)

      state.run != nil ->
        {:reply, {:error, :workspace_busy}, state}

      true ->
        {:reply, do_revert_task(state, run, task), state}
    end
  end

  def handle_call({:revert_run, _run_id}, _from, %{run: %{}} = state),
    do: {:reply, {:error, :workspace_busy}, state}

  def handle_call({:revert_run, _run_id}, _from, %{phase: phase} = state) when phase != nil,
    do: {:reply, {:error, :attempt_running}, state}

  def handle_call({:revert_run, run_id}, _from, state) do
    case Runs.get_run!(run_id) do
      %{workspace_id: workspace_id} when workspace_id != state.workspace.id ->
        {:reply, {:error, :run_not_in_workspace}, state}

      %{reverted_at: %DateTime{}} ->
        {:reply, {:error, :already_reverted}, state}

      %{status: status} when status in [:active, :paused] ->
        {:reply, {:error, :run_not_finished}, state}

      run ->
        {:reply, do_revert_run(state, run), state}
    end
  end

  def handle_call({:run_task, attrs}, _from, state) do
    case Bm.Repo.transaction(fn -> admit_records(state, attrs) end) do
      {:ok, records} ->
        state = assign_attempt(state, records)

        state =
          if state.run.baseline_verify == nil,
            do: start_baseline_verification(state),
            else: start_worker(state)

        {:reply, {:ok, state.attempt}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cancel, _from, %{phase: nil} = state),
    do: {:reply, {:error, :nothing_running}, state}

  def handle_call(:cancel, _from, state), do: {:reply, :ok, request_cancel(state, nil)}

  def handle_call(:keep, _from, %{lane: {:held, attempt_id}} = state) do
    {:reply, :ok, keep_attempt(state, Runs.get_attempt!(attempt_id))}
  end

  def handle_call(:keep, _from, state), do: {:reply, {:error, :nothing_held}, state}

  def handle_call(:revert, _from, %{phase: nil} = state) do
    case revert_latest(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:revert, _from, state), do: {:reply, {:error, :attempt_running}, state}

  def handle_call(:finish_run, _from, %{run: nil} = state),
    do: {:reply, {:error, :no_run}, state}

  def handle_call(:finish_run, _from, %{lane: :free, phase: nil} = state) do
    run = Runs.get_run!(state.run.id)
    {status, reason} = finish_status(run)

    if run.planner do
      if state.planner_ref, do: Process.demonitor(state.planner_ref, [:flush])
      # Asynchronously: the planner may be calling this process right now.
      Task.start(fn -> Bm.Workspace.Planner.stop(run.id) end)

      for task <- Runs.latest_tasks(run), task.status in [:queued, :running] do
        Runs.update_task_status(task, :cancelled)
      end
    end

    run = stored(Runs.finish_run(run, status, reason), run)
    broadcast_run(state, run)
    state = prune_checkpoints(state)
    {:reply, {:ok, run}, %{state | run: nil, attempt: nil, task: nil, planner_ref: nil}}
  end

  def handle_call(:finish_run, _from, state), do: {:reply, {:error, :lane_busy}, state}

  ## Admission (4.4)

  # Everything admission records, in one transaction: nothing is left behind if a step fails.
  defp admit_records(state, attrs) do
    with {:ok, workspace} <- maybe_set_verify_command(state.workspace, attrs),
         :ok <- if(workspace.verify_command, do: :ok, else: {:error, :no_verify_command}),
         {:ok, run} <- ensure_run(state, attrs),
         {:ok, task} <- admit_task(run, attrs),
         {:ok, attempt} <- Runs.create_attempt(task, %{role: role(task)}),
         {:ok, tree_before} <- Git.snapshot(state.root),
         {:ok, run} <- protect_outside_changes(state.root, run, tree_before),
         {:ok, attempt} <-
           Runs.transition_attempt(attempt, :admitted, %{tree_before: tree_before}),
         {:ok, task} <- Runs.update_task_status(task, :running) do
      %{workspace: workspace, run: run, task: task, attempt: attempt}
    else
      {:error, reason} -> Bm.Repo.rollback(reason)
    end
  end

  defp assign_attempt(state, %{workspace: workspace, run: run, task: task, attempt: attempt}) do
    agent_id = "attempt-#{attempt.id}"
    Bm.Pi.subscribe(agent_id)
    state = Map.merge(state, %{tool_calls: 0, steered: MapSet.new(), progress: nil})

    %{
      state
      | workspace: workspace,
        run: run,
        task: task,
        attempt: attempt,
        agent_id: agent_id,
        lane: {:busy, attempt.id},
        phase: :starting,
        seen_running?: false,
        cancel?: false,
        cancel_reason: nil,
        flags: [],
        assignment: nil,
        spend_seen: %{confirmed: 0.0, unknown: 0},
        tool: nil,
        running_since: nil,
        last_event_at: nil,
        tool_since: nil,
        repeats: %{},
        touched: MapSet.new(),
        bash_ran?: false
    }
  end

  defp start_worker(state) do
    coordinator = self()
    %{root: root, agent_id: agent_id, attempt: %{role: role}} = state

    state =
      start_job(%{state | phase: :starting}, :start, fn ->
        Profile.start(agent_id, role, owner: coordinator, cwd: root, approvals: true)
      end)

    broadcast_attempt(state)
  end

  ## Baseline verification (6.6.3)

  # The first attempt of a run waits for one run of the verify command on the checkout as the
  # user left it. Its result is recorded on the run and shown; attempts run either way.
  defp start_baseline_verification(state) do
    coordinator = self()

    %{root: root, workspace: %{verify_command: command}, config: %{verify_timeout: timeout}} =
      state

    state =
      start_job(%{state | phase: :baseline}, :baseline, fn ->
        Bm.Workspace.Verify.run(command, root, timeout, coordinator)
      end)

    broadcast_attempt(state)
  end

  defp baseline_verified(state, result) do
    state = %{state | verify_pgid: nil}

    verify =
      case result do
        %{} = verify -> verify
        other -> %{"exit" => nil, "output" => "verification crashed: #{inspect(other)}"}
      end

    # The verify command may itself change files (generators); those are not the attempt's.
    {changed, state} =
      with {:ok, tree} <- Git.snapshot(state.root),
           {:ok, entries} <- Git.diff(state.root, state.attempt.tree_before, tree) do
        attempt = Runs.update_attempt_fields(state.attempt, %{tree_before: tree})
        {Enum.map(entries, & &1.path), %{state | attempt: attempt}}
      else
        _error -> {[], state}
      end

    {:ok, run} = Runs.set_baseline_verify(state.run, Map.put(verify, "changed", changed))
    Phoenix.PubSub.broadcast(Bm.PubSub, topic(state.root), {:workspace, state.root, {:run, run}})
    state = %{state | run: run}

    if state.cancel?, do: finish(state, :cancelled, %{}), else: start_worker(state)
  end

  # Files changed since BM last touched the workspace were changed by the user (or something
  # else outside BM) during the run: they join the run's user-owned files, like the ones dirty at
  # its start (plan 13.1). BM's last state is the previous attempt's tree_after (tree_before if it
  # was reverted), or the run's baseline tree before the first attempt.
  defp protect_outside_changes(root, run, current_tree) do
    with known when is_binary(known) <- last_known_tree(run),
         true <- known != current_tree,
         {:ok, entries} <- Git.diff(root, known, current_tree) do
      owned = get_in(run.baseline, ["user_owned"]) || []

      case Enum.map(entries, & &1.path) -- owned do
        [] ->
          {:ok, run}

        new ->
          Logger.info(
            "run #{run.id}: protecting files changed outside BM: #{Enum.join(new, ", ")}"
          )

          baseline =
            run.baseline
            |> Map.put("user_owned", owned ++ new)
            |> Map.update("changed_during_run", new, &Enum.uniq(&1 ++ new))

          Runs.update_run(run, %{baseline: baseline})
      end
    else
      _nothing_to_compare -> {:ok, run}
    end
  end

  defp last_known_tree(run) do
    # Attempts that started; the one being admitted has no tree_before yet.
    latest = run |> Runs.list_run_attempts() |> Enum.find(&is_binary(&1.tree_before))
    latest_id = if latest, do: latest.id

    case get_in(run.baseline || %{}, ["known_tree"]) do
      # Recorded after an undo during the run (plan 23.1), while no attempt ran after it.
      %{"tree" => tree, "after_attempt" => ^latest_id} -> tree
      _ -> last_attempt_tree(run, latest)
    end
  end

  defp last_attempt_tree(run, latest) do
    case latest do
      nil -> get_in(run.baseline || %{}, ["tree"])
      %{status: :reverted, tree_before: tree} -> tree
      %{tree_after: tree} when is_binary(tree) -> tree
      %{tree_before: tree} -> tree
    end
  end

  # A queued task of this run (the planner's), or a new one.
  defp admit_task(run, %{task_id: id}) do
    case Runs.get_task!(id) do
      %{run_id: run_id, status: :queued} = task when run_id == run.id -> {:ok, task}
      %{run_id: run_id} when run_id != run.id -> {:error, :run_not_active}
      %{status: status} -> {:error, {:task_not_queued, status}}
    end
  end

  defp admit_task(run, attrs), do: Runs.create_task(run, task_attrs(run, attrs))

  # The run exists by now: if its planner can't start, it ends, or the workspace would hold an
  # unfinished run this coordinator doesn't know (every later start refused as busy, plan 36.8).
  defp start_planner_or_fail(state, run, opts) do
    case start_planner(state, run, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} = error ->
        Runs.finish_run(run, :failed, "the planner did not start: #{inspect(reason)}")
        error
    end
  end

  defp start_planner(state, run, opts) do
    Bm.Workspace.Planner.start(run.id, state.root, opts)
  end

  # A single-task run the user finishes is done. A goal run is done only if its plan is closed
  # and every task was accepted; otherwise the user cancelled it.
  defp finish_status(%{planner: nil}), do: {:done, nil}

  defp finish_status(run) do
    tasks = Runs.latest_tasks(run)

    if not run.plan_open and tasks != [] and Enum.all?(tasks, &(&1.status == :accepted)),
      do: {:done, "finished by the user"},
      else: {:cancelled, "finished by the user before the plan was complete"}
  end

  # A run status write that lost a race (another process changed the run first): what is
  # stored now counts.
  defp stored({:ok, run}, _run), do: run
  defp stored({:error, :stale}, run), do: Runs.get_run!(run.id)

  defp broadcast_run(state, run) do
    Phoenix.PubSub.broadcast(Bm.PubSub, topic(state.root), {:workspace, state.root, {:run, run}})
  end

  ## Reverting a whole run (11.4)

  # Each file goes back to what it was before the first attempt that changed it, only if it
  # still holds what the last attempt that changed it left. (Checking every file against the last
  # attempt's tree would miss the user's edit of a file an earlier attempt wrote: that tree
  # already holds the edit, and it would be lost.) The user's own files are left as they are.
  defp do_revert_run(state, run) do
    case stayed_attempts(run) do
      [] ->
        {:error, :nothing_to_revert}

      stayed ->
        owned = run_user_owned(run)

        restores =
          for path <- written_paths(stayed), path not in owned do
            writers = writers(stayed, path)
            {path, hd(writers).tree_before, List.last(writers).tree_after}
          end

        with :ok <- Git.restore_paths(state.root, restores) do
          for attempt <- stayed do
            left = left_for_user(attempt, owned)

            case Runs.transition_attempt(attempt, :reverted, note_left(%{}, attempt, left)) do
              {:ok, _} ->
                :ok

              # A kept failed/cancelled attempt that can't move: the files are back anyway.
              {:error, _} ->
                Runs.add_attempt_flag(attempt, "run_reverted")
                if left != [], do: Runs.add_attempt_flag(attempt, "user_files_left")
            end
          end

          {:ok, run} = Runs.update_run(run, %{reverted_at: DateTime.utc_now()})
          broadcast_run(state, run)
          {:ok, run}
        end
    end
  end

  ## Committing a run (15.1, D26)

  # The user's own files are left out (§8: user changes are never committed): a kept attempt
  # may have written one (e.g. a verify command that formats files), and committing it would
  # commit the user's uncommitted work with it. The run names them (`baseline["commit_left"]`).
  defp do_commit_run(state, run) do
    stayed = stayed_attempts(run)
    owned = run_user_owned(run)
    {left, paths} = stayed |> written_paths() |> Enum.split_with(&(&1 in owned))

    # The run's final content of each path: from the last attempt that wrote it.
    final = Map.new(paths, &{&1, List.last(writers(stayed, &1)).tree_after})

    changed =
      Enum.filter(paths, fn path ->
        match?({:ok, true}, Git.changed_since?(state.root, final[path], path))
      end)

    cond do
      paths == [] and left != [] ->
        {:error, {:only_user_files, left}}

      paths == [] ->
        {:error, :nothing_to_commit}

      changed != [] ->
        {:error, {:changed_since, changed}}

      true ->
        label = "BM-#{run.id}"

        subject = commit_subject(run.goal)

        message = "#{subject}\n\nChanges made by BM run #{label} and accepted.\n"

        with {:ok, sha, notes} <- commit_paths(state.root, paths, message) do
          baseline =
            (run.baseline || %{})
            |> Map.put("commit_left", left)
            |> Map.put("commit_notes", notes)

          {:ok, run} = Runs.update_run(run, %{commit_sha: sha, baseline: baseline})
          broadcast_run(state, run)
          {:ok, run}
        end
    end
  end

  defp commit_paths(root, paths, message) do
    case Git.commit_paths(root, paths, message) do
      {:ok, sha} -> {:ok, sha, []}
      {:ok, sha, :index_not_refreshed} -> {:ok, sha, ["index_not_refreshed"]}
      error -> error
    end
  end

  ## Changes that stayed, and the user's files

  # The run's attempts whose changes stayed in the workspace, in order: accepted, or kept by the
  # user and not reverted since.
  defp stayed_attempts(run) do
    run
    |> Runs.list_run_attempts()
    |> Enum.sort_by(& &1.id)
    |> Enum.filter(fn a ->
      a.actual_writes != [] and is_binary(a.tree_before) and is_binary(a.tree_after) and
        (a.status == :accepted or (a.status != :reverted and "kept" in a.flags))
    end)
  end

  defp write_paths(attempt), do: Enum.map(attempt.actual_writes, & &1["path"])
  defp written_paths(attempts), do: attempts |> Enum.flat_map(&write_paths/1) |> Enum.uniq()
  defp writers(attempts, path), do: Enum.filter(attempts, &(path in write_paths(&1)))

  # The user's files: dirty when the run began, or changed outside BM during it (13.1).
  defp run_user_owned(run), do: get_in(run.baseline || %{}, ["user_owned"]) || []

  # A revert never puts the user's own files back. The policy refuses the worker's edits to them,
  # so a change there is most likely the user's, made while BM ran, and putting the file back
  # would lose it. They stay as they are; the attempt names them and where their earlier version
  # is (the tree before the attempt).
  defp left_for_user(attempt, owned), do: Enum.filter(write_paths(attempt), &(&1 in owned))

  defp revertible_writes(attempt, left),
    do: Enum.reject(attempt.actual_writes, &(&1["path"] in left))

  defp note_left(attrs, _attempt, []), do: attrs

  defp note_left(attrs, attempt, left) do
    note =
      "BM left your files #{Enum.join(left, ", ")} as they are; their versions from before " <>
        "the attempt: git show #{String.slice(attempt.tree_before, 0, 12)}:<path>"

    error = Enum.join(Enum.reject([attrs[:error] || attempt.error, note], &is_nil/1), "; ")
    flags = Map.get(attrs, :flags, attempt.flags) ++ ["user_files_left"]
    Map.merge(attrs, %{error: error, flags: flags})
  end

  # The goal's first line, cut at a word boundary to fit a git subject line.
  defp commit_subject(goal) do
    line = goal |> String.split("\n", trim: true) |> List.first("") |> String.trim()

    if String.length(line) <= 72 do
      line
    else
      words = line |> String.slice(0, 71) |> String.split(" ")
      cut = if length(words) > 1, do: words |> Enum.drop(-1) |> Enum.join(" "), else: hd(words)
      String.trim_trailing(cut, ",.;:") <> "…"
    end
  end

  ## Undoing one task (13.3)

  # Undo in an unfinished run (plan 23.1): a goal run only while paused (its planner is not
  # scheduling, so the undo can't land inside a planner turn), a single-task run while nothing
  # runs; never while changes wait for the user. BM records the workspace after the undo as its
  # own last state (13.1), and a goal run's planner is told at its next scheduling.
  defp revert_task_in_run(state, run, task) do
    cond do
      state.run == nil or state.run.id != run.id ->
        {:reply, {:error, :workspace_busy}, state}

      state.lane != :free ->
        {:reply, {:error, :lane_held}, state}

      run.planner != nil and run.status != :paused ->
        {:reply, {:error, :run_not_paused}, state}

      true ->
        case do_revert_task(state, run, task) do
          {:ok, task} ->
            {:ok, run} = remember_workspace(state.root, run)
            if run.planner, do: Runs.drop_delivery(task)
            broadcast_run(state, run)
            {:reply, {:ok, task}, %{state | run: run}}

          error ->
            {:reply, error, state}
        end
    end
  end

  # BM's own change to the workspace outside an attempt: the next admission must not take it for
  # the user's (plan 13.1, last_known_tree/1). Valid while the latest attempt is still the latest.
  defp remember_workspace(root, run) do
    with {:ok, tree} <- Git.snapshot(root) do
      latest = run |> Runs.list_run_attempts() |> Enum.find(&is_binary(&1.tree_before))
      known = %{"tree" => tree, "after_attempt" => latest && latest.id}
      Runs.update_run(run, %{baseline: Map.put(run.baseline || %{}, "known_tree", known)})
    else
      _ -> {:ok, run}
    end
  end

  defp do_revert_task(state, run, task) do
    attempt =
      task
      |> Runs.latest_attempt()
      |> case do
        %{status: :accepted, actual_writes: [_ | _]} = a ->
          a

        %{status: status, actual_writes: [_ | _], flags: flags} = a when status != :reverted ->
          if "kept" in flags, do: a

        _ ->
          nil
      end

    dependents =
      for t <- Runs.latest_tasks(run), task.key in t.depends_on, t.status == :accepted, do: t.key

    cond do
      attempt == nil ->
        {:error, :nothing_to_revert}

      dependents != [] ->
        {:error, {:dependents, dependents}}

      true ->
        left = left_for_user(attempt, run_user_owned(run))

        attrs =
          note_left(
            %{
              flags: attempt.flags ++ ["undone"],
              error: "undone by the user; its changes are reverted"
            },
            attempt,
            left
          )

        with :ok <-
               Git.restore(
                 state.root,
                 revertible_writes(attempt, left),
                 attempt.tree_before,
                 attempt.tree_after
               ),
             {:ok, attempt} <- Runs.transition_attempt(attempt, :reverted, attrs) do
          {:ok, task} = Runs.update_task_status(task, :cancelled)

          Phoenix.PubSub.broadcast(
            Bm.PubSub,
            topic(state.root),
            {:workspace, state.root, {:attempt, attempt, state.lane}}
          )

          {:ok, task}
        end
    end
  end

  ## Pruning checkpoints

  @keep_checkpoint_runs 20

  # After a run ends: checkpoint refs of the workspace's newest runs are kept (the workspace
  # setting "keep_checkpoint_runs", default #{@keep_checkpoint_runs}); older runs' refs are
  # deleted in the background. Runs never share checkpoint commits, so this can't affect a
  # kept run.
  defp prune_checkpoints(state) do
    %{root: root, workspace: workspace} = state
    keep = workspace.settings["keep_checkpoint_runs"] || @keep_checkpoint_runs

    Task.Supervisor.start_child(Bm.TaskSupervisor, fn ->
      kept = workspace |> Runs.list_run_ids() |> Enum.take(keep) |> MapSet.new()

      for run_id <- Git.checkpoint_runs(root), not MapSet.member?(kept, run_id) do
        case Git.delete_checkpoints(root, run_id) do
          :ok ->
            Logger.info("pruned the checkpoints of run #{run_id} in #{root}")

          error ->
            Logger.warning("could not prune run #{run_id}'s checkpoints: #{inspect(error)}")
        end
      end
    end)

    state
  end

  defp maybe_set_verify_command(workspace, %{verify_command: command}) when is_binary(command),
    do: Runs.update_workspace(workspace, %{verify_command: command})

  defp maybe_set_verify_command(workspace, _attrs), do: {:ok, workspace}

  # Reloaded: recovery or another process may have paused or ended it since this state was read.
  defp ensure_run(%{run: %{status: :active} = run}, _attrs) do
    run = Runs.get_run!(run.id)

    cond do
      run.status == :paused -> {:error, :run_paused}
      run.status != :active -> {:error, :run_not_active}
      Runs.budget_exhausted?(run) -> {:error, :budget_exhausted}
      true -> {:ok, run}
    end
  end

  defp ensure_run(%{run: %{status: :paused}}, _attrs), do: {:error, :run_paused}

  defp ensure_run(state, attrs) do
    with {:ok, baseline} <- Git.baseline(state.root) do
      Runs.start_run(state.workspace, %{
        goal: attrs[:run_goal] || attrs[:title] || "Task",
        budget_usd: attrs[:budget_usd],
        baseline: %{
          "head" => baseline.head,
          "tree" => baseline.tree,
          "user_owned" => baseline.user_owned
        }
      })
    end
  end

  defp task_attrs(run, attrs) do
    key = attrs[:key] || "task_#{length(Runs.list_tasks(run)) + 1}"

    attrs
    |> Map.take([:title, :goal, :done_when, :mutates, :writes, :depends_on])
    |> Map.put(:key, key)
    |> Map.put_new(:mutates, true)
  end

  defp role(%{mutates: true}), do: :writer
  defp role(_task), do: :reader

  defp user_owned(%{run: %{baseline: %{"user_owned" => owned}}}), do: owned
  defp user_owned(_state), do: []

  ## Jobs

  defp start_job(state, kind, fun) do
    # Linked: if the coordinator dies, its jobs die with it (recovery handles the attempt).
    %Task{ref: ref} = Task.Supervisor.async(Bm.TaskSupervisor, fun)
    %{state | job: {ref, kind}}
  end

  @impl true
  def handle_info({ref, result}, %{job: {ref, kind}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, job_done(%{state | job: nil}, kind, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job: {ref, kind}} = state) do
    {:noreply, job_done(%{state | job: nil}, kind, {:error, {:job_crashed, reason}})}
  end

  # The goal run's planner stopped without ending the run: pause it for the user.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{planner_ref: ref} = state) do
    state = %{state | planner_ref: nil}

    case state.run && Runs.get_run!(state.run.id) do
      %{status: :active} = run ->
        run =
          stored(
            Runs.pause_run(run, "the planner stopped unexpectedly (#{inspect(reason)})"),
            run
          )

        broadcast_run(state, run)
        {:noreply, %{state | run: run}}

      _other ->
        {:noreply, state}
    end
  end

  # The worker's pi adapter died: settle with what we know.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{agent_ref: ref} = state) do
    state = %{state | agent_ref: nil, flags: ["agent_down" | state.flags]}
    {:noreply, if(state.phase == :running, do: begin_settling(state), else: state)}
  end

  ## Worker events and requests (4.5, 4.6)

  def handle_info({:pi, id, event, summary}, %{agent_id: id} = state) do
    state =
      state
      |> track_tool(summary[:tool])
      |> Map.put(:last_event_at, now())
      |> track_spend(summary)
      |> enforce_budget()

    {:noreply, worker_event(state, event, summary)}
  end

  def handle_info({:pi, _id, _event, _summary}, state), do: {:noreply, state}

  # A worker's question for the planner is answered later (a planner turn); see ask_planner/2.
  def handle_info({:pi_request, id, %{op: "ask_planner"} = request}, %{agent_id: id} = state),
    do: {:noreply, ask_planner(state, request)}

  # Another extension asks the user (plan 24.1): shown on the run page until answered, declined
  # after approval_timeout (or pi's own timeout, if sooner).
  def handle_info({:pi_request, id, %{op: "approval"} = request}, %{agent_id: id} = state) do
    timeout =
      case request.payload["timeout"] do
        ms when is_integer(ms) and ms > 0 -> min(ms, state.config.approval_timeout)
        _ -> state.config.approval_timeout
      end

    approval = %{
      id: request.dialog_id,
      attempt_id: state.attempt.id,
      payload: request.payload,
      since: DateTime.utc_now(),
      timeout: timeout,
      timer: Process.send_after(self(), {:approval_timeout, request.dialog_id}, timeout)
    }

    approvals = Map.put(Map.get(state, :approvals, %{}), request.dialog_id, approval)
    {:noreply, broadcast_approvals(Map.put(state, :approvals, approvals))}
  end

  def handle_info({:approval_timeout, dialog_id}, state) do
    case Map.get(state, :approvals, %{}) do
      %{^dialog_id => _approval} ->
        {:noreply, reply_approval(state, dialog_id, %{"cancelled" => true})}

      _answered ->
        {:noreply, state}
    end
  end

  def handle_info({:pi_request, id, request}, %{agent_id: id} = state) do
    {outcome, state} = handle_request(state, request)
    Bm.Pi.respond(id, request.dialog_id, outcome)
    {:noreply, state}
  end

  def handle_info({ref, answer}, %{asks: asks} = state) when is_map_key(asks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, answer_ask(state, ref, answer)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{asks: asks} = state)
      when is_map_key(asks, ref),
      do: {:noreply, answer_ask(state, ref, @no_planner_answer)}

  # A request from an agent that is no longer this coordinator's worker.
  def handle_info({:pi_request, id, request}, state) do
    Bm.Pi.respond(id, request.dialog_id, %{"ok" => false, "error" => "not_assigned"})
    {:noreply, state}
  end

  def handle_info(:limits_check, %{phase: :running, cancel?: false} = state),
    do: {:noreply, check_limits(state)}

  def handle_info(:limits_check, state), do: {:noreply, state}

  def handle_info(:settle_check, %{phase: :settling} = state), do: {:noreply, settle_check(state)}
  def handle_info(:settle_check, state), do: {:noreply, state}

  # The baseline verify command is recorded on the attempt like the attempt's own verification
  # (overwritten later), so recovery can end it if this coordinator dies.
  def handle_info({:verify_started, pgid}, %{phase: :baseline} = state) do
    if state.cancel?, do: Bm.Proc.terminate_groups([pgid])

    attempt =
      Runs.update_attempt_fields(state.attempt, %{
        verify: %{"pgid" => pgid, "boot_id" => Bm.Proc.boot_id(), "baseline" => true}
      })

    {:noreply, %{state | verify_pgid: pgid, attempt: attempt}}
  end

  def handle_info({:verify_started, pgid}, %{phase: :verifying} = state) do
    if state.cancel?, do: Bm.Proc.terminate_groups([pgid])

    # Recorded so that recovery can end the verify command if this coordinator dies.
    attempt =
      Runs.update_attempt_fields(state.attempt, %{
        verify: %{"pgid" => pgid, "boot_id" => Bm.Proc.boot_id()}
      })

    {:noreply, %{state | verify_pgid: pgid, attempt: attempt}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp worker_event(state, :status, %{status: :running}), do: %{state | seen_running?: true}

  defp worker_event(%{phase: :running, seen_running?: true} = state, :status, %{status: :idle}),
    do: begin_settling(state)

  defp worker_event(%{phase: :running} = state, _event, %{status: :exited}),
    do: begin_settling(%{state | flags: ["pi_exited" | state.flags]})

  defp worker_event(state, {:tool_start, _id, _name, _detail}, _summary),
    do: Map.update(state, :tool_calls, 1, &(&1 + 1))

  defp worker_event(state, _event, _summary), do: state

  ## Questions for the planner (12.2, D24)

  # Checked like any bridge request; answered by the planner's answer turn in a task, so this
  # process keeps answering the worker's other requests and can cancel.
  defp ask_planner(state, request) do
    agent_id = state.agent_id

    case Bm.Bridge.check(:worker, agent_id, request, state.assignment) do
      {:error, outcome} ->
        Bm.Pi.respond(agent_id, request.dialog_id, outcome)
        state

      {:duplicate, outcome} ->
        Bm.Pi.respond(agent_id, request.dialog_id, outcome)
        state

      :ok when state.run.planner == nil ->
        outcome =
          Bm.Bridge.record(:worker, agent_id, request, state.assignment, @no_planner_answer)

        Bm.Pi.respond(agent_id, request.dialog_id, outcome)
        state

      :ok ->
        %{run: %{id: run_id}, task: task} = state
        question = to_string(request.payload["question"] || "")

        %Task{ref: ref} =
          Task.Supervisor.async_nolink(Bm.TaskSupervisor, fn ->
            Bm.Workspace.Planner.answer(run_id, task, question, @ask_timeout)
          end)

        %{state | asks: Map.put(state.asks, ref, {agent_id, request, state.assignment})}
    end
  end

  defp answer_ask(state, ref, answer) do
    {{agent_id, request, assignment}, asks} = Map.pop(state.asks, ref)

    answer =
      if match?(%{"ok" => true, "answer" => _}, answer), do: answer, else: @no_planner_answer

    outcome = Bm.Bridge.record(:worker, agent_id, request, assignment, answer)
    # Answered even if the attempt ended meanwhile: an unknown dialog is ignored by the adapter.
    Bm.Pi.respond(agent_id, request.dialog_id, outcome)
    %{state | asks: asks}
  end

  ## Limits (5.1, 5.2, 11.5)

  defp track_tool(%{tool: tool} = state, tool), do: state
  defp track_tool(state, nil), do: %{state | tool: nil, tool_since: nil}
  defp track_tool(state, tool), do: %{state | tool: tool, tool_since: now()}

  defp now, do: System.monotonic_time(:millisecond)

  # Adds what the worker spent since the last summary to the run: confirmed USD, and usage
  # entries without a cost as unknown (never as 0).
  defp track_spend(state, %{spend: %{confirmed: confirmed, unknown: unknown}}) do
    seen = state.spend_seen
    delta = confirmed - seen.confirmed
    unknown_delta = unknown - seen.unknown

    if delta > 0 or unknown_delta > 0 do
      run = Runs.add_spend(state.run, max(delta, 0.0), max(unknown_delta, 0))

      Phoenix.PubSub.broadcast(
        Bm.PubSub,
        topic(state.root),
        {:workspace, state.root, {:run, run}}
      )

      %{state | run: run, spend_seen: %{confirmed: confirmed, unknown: unknown}}
    else
      state
    end
  end

  defp track_spend(state, _summary), do: state

  defp enforce_budget(%{phase: phase, cancel?: false} = state)
       when phase in [:starting, :running] do
    if Runs.budget_exhausted?(state.run), do: request_cancel(state, "budget"), else: state
  end

  defp enforce_budget(state), do: state

  defp schedule_limits_check(state) do
    interval = min(state.config.max_duration, state.config.stall_timeout) |> div(4)
    Process.send_after(self(), :limits_check, interval |> min(1_000) |> max(10))
    state
  end

  defp check_limits(state) do
    cond do
      now() - state.running_since >= state.config.max_duration ->
        request_cancel(state, "max_duration")

      # A question to the user holds the silence clock, like a running tool (plan 24.1).
      state.tool == nil and Map.get(state, :approvals, %{}) == %{} and
          now() - state.last_event_at >= state.config.stall_timeout ->
        request_cancel(state, "stall")

      state.tool != nil and state.tool_since != nil and
          now() - state.tool_since >= state.config.tool_timeout ->
        request_cancel(state, "tool_timeout")

      true ->
        case check_progress(state) do
          %{cancel?: true} = state -> state
          state -> schedule_limits_check(state)
        end
    end
  end

  ## Supervisor (25.1)

  # A write outside the task's declared files is allowed and flagged at the end, as before; the
  # worker is also told at once, once per file.
  defp steer_drift(
         state,
         %{op: "authorize", payload: %{"tool" => tool, "input" => %{"path" => path}}},
         %{"allow" => true}
       )
       when tool in ["edit", "write"] and is_binary(path) do
    relative = relative_path(state.root, path)
    writes = state.task.writes || []
    steered = Map.get(state, :steered, MapSet.new())

    if writes == [] or relative in writes or MapSet.member?(steered, relative) do
      state
    else
      steer(
        state,
        "#{relative} is not among this task's files (#{Enum.join(writes, ", ")}). Change it " <>
          "only if the task needs it; otherwise leave it and stay on the task."
      )

      Map.put(state, :steered, MapSet.put(steered, relative))
    end
  end

  defp steer_drift(state, _request, _outcome), do: state

  # A writing attempt that ran a while with many tool calls but changed no file is told once;
  # if it still changes nothing after as long again, it is cancelled.
  defp check_progress(%{attempt: %{role: :writer}} = state) do
    after_ms = Map.get(state.config, :progress_after, 6 * 60_000)
    calls = Map.get(state, :tool_calls, 0)

    since_steer =
      case Map.get(state, :progress) do
        {:steered, at} -> now() - at
        _ -> nil
      end

    cond do
      Map.get(state, :progress) == :changed ->
        state

      calls < Map.get(state.config, :progress_calls, 30) or now() - state.running_since < after_ms ->
        state

      is_integer(since_steer) and since_steer < after_ms ->
        state

      changed_any?(state) ->
        Map.put(state, :progress, :changed)

      since_steer == nil ->
        span =
          if after_ms >= 60_000,
            do: "#{div(after_ms, 60_000)} minutes",
            else: "#{div(after_ms, 1000)} seconds"

        steer(
          state,
          "After #{span} and #{calls} tool calls this attempt has changed no file. " <>
            "Make the change the task asks for now, or if you are stuck, submit_result with " <>
            "status blocked and say what blocks you."
        )

        Map.put(state, :progress, {:steered, now()})

      true ->
        request_cancel(state, "no progress: #{calls} tool calls and no changed file")
    end
  end

  defp check_progress(state), do: state

  defp changed_any?(state) do
    with {:ok, tree} <- Git.snapshot(state.root),
         {:ok, entries} <- Git.diff(state.root, state.attempt.tree_before, tree) do
      entries != []
    else
      # Can't tell: no action against the worker.
      _ -> true
    end
  end

  defp steer(state, text) do
    agent_id = state.agent_id

    Task.start(fn ->
      try do
        Bm.Pi.steer(agent_id, text)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp handle_request(state, request) do
    state = count_repeat(state, request)

    {outcome, state} = handle_request_once(state, request)
    state = note_allowed(state, request, outcome)
    state = steer_drift(state, request, outcome)

    if repeats(state, request) >= state.config.repeat_cancel,
      do: {outcome, request_cancel(state, "repeating the same call")},
      else: {outcome, state}
  end

  # What the worker was allowed to do so far, for the freshness check (13.2).
  defp note_allowed(state, %{op: "authorize", payload: payload}, %{"allow" => true}) do
    case payload do
      # The files the command names as written count as the worker's own (plan 36.6).
      %{"tool" => "bash", "input" => %{"command" => command}} when is_binary(command) ->
        touched = command |> Bm.Policy.write_targets(state.root) |> MapSet.new()
        %{state | bash_ran?: true, touched: MapSet.union(state.touched, touched)}

      %{"tool" => "bash"} ->
        %{state | bash_ran?: true}

      %{"tool" => tool, "input" => %{"path" => path}} when tool in ["edit", "write"] ->
        %{state | touched: MapSet.put(state.touched, relative_path(state.root, path))}

      _other ->
        state
    end
  end

  defp note_allowed(state, _request, _outcome), do: state

  defp relative_path(root, path),
    do: path |> String.replace_prefix("@", "") |> Path.expand(root) |> Path.relative_to(root)

  # A `write` replaces the whole file. If the file changed since the attempt started and not by
  # this worker (no earlier edit/write of it, no bash that could have), someone else changed it
  # meanwhile: refuse rather than overwrite (13.2). `edit` needs no check: pi re-reads the file
  # and fails if the text to replace changed.
  defp freshness(state, "write", %{"path" => path}) when is_binary(path) do
    relative = relative_path(state.root, path)

    cond do
      state.bash_ran? or MapSet.member?(state.touched, relative) ->
        :ok

      not File.regular?(Path.join(state.root, relative)) ->
        :ok

      true ->
        case Git.changed_since?(state.root, state.attempt.tree_before, relative) do
          {:ok, true} ->
            {:deny,
             "#{relative} changed since your task started, and not by you. Read it again and " <>
               "use edit for your change, or report the task as blocked."}

          _unchanged_or_unknown ->
            :ok
        end
    end
  end

  defp freshness(_state, _tool, _input), do: :ok

  # Identical guarded tool calls (same tool, same input) in this attempt.
  defp count_repeat(state, %{op: "authorize", payload: payload}) do
    key = repeat_key(payload)
    %{state | repeats: Map.update(state.repeats, key, 1, &(&1 + 1))}
  end

  defp count_repeat(state, _request), do: state

  defp repeats(state, %{op: "authorize", payload: payload}),
    do: Map.get(state.repeats, repeat_key(payload), 0)

  defp repeats(_state, _request), do: 0

  defp repeat_key(payload), do: :erlang.phash2({payload["tool"], payload["input"]})

  defp handle_request_once(state, request) do
    Bm.Bridge.handle(:worker, state.agent_id, request, state.assignment, fn request ->
      case request.op do
        "authorize" -> authorize(state, request.payload)
        "submit_result" -> submit_result(state, request.payload)
      end
    end)
    |> case do
      %{"ok" => true, "status" => "received"} = outcome ->
        {outcome, %{state | attempt: Runs.get_attempt!(state.attempt.id)}}

      outcome ->
        {outcome, state}
    end
  end

  defp authorize(state, %{"tool" => tool} = payload) do
    count = Map.get(state.repeats, repeat_key(payload), 0)

    if count >= state.config.repeat_refuse do
      %{
        "ok" => true,
        "allow" => false,
        "reason" =>
          "You have made this exact #{tool} call #{count} times; repeating it will not help. " <>
            "Try a different approach, or submit_result with status blocked and say why."
      }
    else
      authorize_policy(state, tool, payload)
    end
  end

  defp authorize(_state, _payload), do: %{"ok" => false, "error" => "malformed_authorize"}

  defp authorize_policy(state, tool, payload) do
    mode = if state.attempt.role == :reader, do: :read_only, else: :write
    ctx = %{root: state.root, user_owned: user_owned(state), mode: mode, touched: state.touched}

    input = payload["input"] || %{}

    with :allow <- Bm.Policy.authorize(tool, input, ctx),
         :ok <- freshness(state, tool, input) do
      %{"ok" => true, "allow" => true}
    else
      {:deny, reason} -> %{"ok" => true, "allow" => false, "reason" => reason}
    end
  end

  defp submit_result(state, payload) do
    attempt = Runs.get_attempt!(state.attempt.id)

    case Runs.transition_attempt(attempt, :result_received, %{result: payload}) do
      {:ok, _} -> %{"ok" => true, "status" => "received"}
      {:error, _} -> %{"ok" => false, "error" => "result_not_expected"}
    end
  end

  ## Start

  defp job_done(state, :start, {:ok, report}) do
    case Registry.lookup(Bm.Pi.Registry, state.agent_id) do
      [{agent_pid, _}] -> worker_started(state, agent_pid)
      [] -> job_done(state, :start, {:error, {:agent_gone_after_start, report}})
    end
  end

  defp job_done(state, :start, error) do
    Bm.Pi.unsubscribe(state.agent_id)

    reason =
      case error do
        {:error, reason} -> reason
        other -> other
      end

    if state.cancel?,
      do: finish(state, :cancelled, %{}),
      else: finish(state, :failed, %{error: "worker did not start: #{inspect(reason)}"})
  end

  defp job_done(state, :stop, {:transcript, [_ | _] = transcript}) do
    attempt = Runs.update_attempt_fields(state.attempt, %{transcript: transcript})
    stopped(%{state | attempt: attempt})
  end

  defp job_done(state, :stop, _result), do: stopped(state)
  defp job_done(state, :verify, result), do: verified(state, result)
  defp job_done(state, :baseline, result), do: baseline_verified(state, result)
  defp job_done(state, :review, result), do: job_done_review(state, result)

  defp worker_started(state, agent_pid) do
    summary = Bm.Pi.snapshot(state.agent_id).summary

    # seen_running? restarts here: a start-up status event may arrive after the start result.
    state = %{
      state
      | agent_ref: Process.monitor(agent_pid),
        seen_running?: false,
        assignment: %{session_epoch: summary.session_epoch, attempt_id: state.attempt.id}
    }

    {:ok, attempt} =
      Runs.transition_attempt(state.attempt, :running, %{
        agent_id: state.agent_id,
        session_epoch: summary.session_epoch,
        pgid: summary.pgid,
        pgid_file: summary.pgid_file,
        boot_id: Bm.Proc.boot_id()
      })

    state =
      %{state | attempt: attempt, phase: :running, running_since: now(), last_event_at: now()}
      |> broadcast_attempt()
      |> schedule_limits_check()

    cond do
      state.cancel? ->
        stop_worker(state)

      Bm.Pi.prompt(state.agent_id, worker_prompt(state)) == :ok ->
        state

      true ->
        stop_worker(%{state | flags: ["prompt_failed" | state.flags]})
    end
  end

  defp worker_prompt(%{config: %{prompt: prompt}, task: task}) when is_function(prompt, 2),
    do: prompt.(task, Runs.dependency_context(task))

  defp worker_prompt(%{config: %{prompt: prompt}, task: task}), do: prompt.(task)

  ## Settling (4.6)

  defp begin_settling(state) do
    attempt = Runs.get_attempt!(state.attempt.id)
    {:ok, attempt} = Runs.transition_attempt(attempt, :settling)
    deadline = System.monotonic_time(:millisecond) + state.config.settle_timeout

    state =
      broadcast_attempt(%{state | attempt: attempt, phase: :settling, settle_deadline: deadline})

    if state.cancel?, do: stop_worker(state), else: settle_check(state)
  end

  # Settled when nothing but pi itself is left in pi's group and every recorded group is empty.
  defp settle_check(state) do
    cond do
      leftover_processes(state) == [] ->
        stop_worker(state)

      System.monotonic_time(:millisecond) >= state.settle_deadline ->
        stop_worker(%{state | flags: ["leftover_processes" | state.flags]})

      true ->
        Process.send_after(self(), :settle_check, state.config.settle_interval)
        state
    end
  end

  defp leftover_processes(state) do
    pgid = state.attempt.pgid

    groups =
      if state.agent_ref,
        do: safe_process_groups(state.agent_id),
        else: Bm.Proc.live_groups(recorded_groups(state.attempt))

    Bm.Proc.group_members(groups) -- [pgid]
  end

  defp safe_process_groups(agent_id) do
    Bm.Pi.process_groups(agent_id)
  catch
    :exit, _ -> []
  end

  defp recorded_groups(%Attempt{pgid: nil}), do: []

  defp recorded_groups(%Attempt{pgid: pgid, pgid_file: file}),
    do: [pgid | Bm.Proc.read_pgid_file(file)]

  ## Stopping

  defp stop_worker(state) do
    agent_id = state.agent_id
    alive? = state.agent_ref != nil
    cancel? = state.cancel?
    orphans = if alive?, do: [], else: Bm.Proc.live_groups(recorded_groups(state.attempt))
    if state.agent_ref, do: Process.demonitor(state.agent_ref, [:flush])

    state = %{state | phase: :stopping, agent_ref: nil}

    start_job(state, :stop, fn ->
      if alive? and cancel?, do: safe_abort(agent_id)
      # What the worker did, read before its session goes away (plan 10.4).
      transcript = if alive?, do: safe_transcript(agent_id), else: []
      Bm.Pi.stop(agent_id)
      # Groups of an adapter that died without cleaning up.
      Bm.Proc.terminate_groups(orphans)
      {:transcript, transcript}
    end)
  end

  @max_transcript 300
  @max_text 1_500

  defp safe_transcript(agent_id) do
    agent_id
    |> Bm.Pi.snapshot()
    |> Map.fetch!(:transcript)
    |> Enum.flat_map(&compact_entry/1)
    |> Enum.take(-@max_transcript)
  catch
    :exit, _ -> []
  end

  # The prompt is the task (already stored); tool calls and the worker's words are kept.
  defp compact_entry(%{role: :tool, name: name, detail: detail, status: status}),
    do: [%{"t" => "tool", "name" => name, "detail" => detail, "status" => to_string(status)}]

  defp compact_entry(%{role: :assistant, text: text}) when text != "",
    do: [%{"t" => "text", "text" => String.slice(text, 0, @max_text)}]

  defp compact_entry(%{role: role, text: text}) when role in [:error, :notice],
    do: [%{"t" => to_string(role), "text" => String.slice(text, 0, @max_text)}]

  defp compact_entry(_entry), do: []

  defp safe_abort(agent_id) do
    Bm.Pi.abort(agent_id)
  catch
    :exit, _ -> :ok
  end

  defp stopped(state) do
    Bm.Pi.unsubscribe(state.agent_id)
    attribute(state)
  end

  ## Attribution (4.6)

  defp attribute(state) do
    attempt = Runs.get_attempt!(state.attempt.id)

    with {:ok, tree_after} <- Git.snapshot(state.root),
         {:ok, entries} <- Git.diff(state.root, attempt.tree_before, tree_after) do
      writes = Enum.map(entries, &write_entry/1)
      paths = Enum.map(entries, & &1.path)
      touched_user_files = Enum.filter(paths, &(&1 in user_owned(state)))
      undeclared = if state.task.writes == [], do: [], else: paths -- state.task.writes

      flags =
        state.flags
        |> add_flag(undeclared != [], "undeclared_writes")
        |> add_flag(touched_user_files != [], "user_owned_writes")
        |> Enum.reverse()

      attrs = %{tree_after: tree_after, actual_writes: writes, flags: flags}
      result = attempt.result || %{}

      cond do
        state.cancel? ->
          finish(state, :cancelled, attrs)

        touched_user_files != [] ->
          error = "changed the user's uncommitted files: #{Enum.join(touched_user_files, ", ")}"
          finish(state, :failed, Map.put(attrs, :error, error))

        attempt.role == :reader and writes != [] ->
          finish(state, :failed, Map.put(attrs, :error, "a read-only task changed files"))

        attempt.status != :settling ->
          finish(state, :failed, Map.put(attrs, :error, "unexpected status #{attempt.status}"))

        result["status"] != "done" ->
          error =
            if result == %{},
              do: "the worker finished without submitting a result",
              else: "the worker reported #{result["status"]}: #{result["summary"]}"

          finish(state, :failed, Map.put(attrs, :error, error))

        # Nothing changed but the task has a check (a read-only task whose point is running it,
        # found in the 15.3 trial): run the check alone; the verify command can't show anything
        # new without changes.
        writes == [] and is_binary(state.task.check) ->
          {:ok, attempt} = Runs.transition_attempt(attempt, :verifying, attrs)

          start_verification(
            broadcast_attempt(%{state | attempt: attempt, phase: :verifying}),
            :check_only
          )

        writes == [] ->
          # Nothing changed, so there is nothing to verify or checkpoint.
          {:ok, attempt} = Runs.transition_attempt(attempt, :verifying, attrs)
          state = %{state | attempt: attempt}
          finish(state, :accepted, %{verify: %{"skipped" => "no changes"}})

        true ->
          {:ok, attempt} = Runs.transition_attempt(attempt, :verifying, attrs)
          start_verification(broadcast_attempt(%{state | attempt: attempt, phase: :verifying}))
      end
    else
      error ->
        finish(state, :needs_reconciliation, %{error: "snapshot failed: #{inspect(error)}"})
    end
  end

  defp add_flag(flags, true, flag), do: [flag | flags]
  defp add_flag(flags, false, _flag), do: flags

  ## Verification (4.7)

  defp start_verification(state, :check_only) do
    coordinator = self()
    %{root: root, task: %{check: check}, config: %{verify_timeout: timeout}} = state
    owned = run_user_owned(state.run)

    start_job(state, :verify, fn ->
      check_result = run_check(check, root, owned, timeout, coordinator)
      %{"exit" => 0, "output" => "", "skipped" => "no changes", "check" => check_result}
    end)
  end

  defp start_verification(state) do
    coordinator = self()
    root = state.root
    command = state.workspace.verify_command
    check = state.task.check
    timeout = state.config.verify_timeout
    owned = run_user_owned(state.run)

    # The task's check (plan 7.7) runs only after the workspace verify command passed.
    start_job(state, :verify, fn ->
      case Bm.Workspace.Verify.run(command, root, timeout, coordinator) do
        %{"exit" => 0} = verify when is_binary(check) ->
          Map.put(verify, "check", run_check(check, root, owned, timeout, coordinator))

        verify ->
          verify
      end
    end)
  end

  # A task's check is checked again where it runs (plan 36.4): a refused one fails like a
  # failing check, without running.
  defp run_check(check, root, owned, timeout, coordinator) do
    case Bm.Plan.check_policy(check, root, owned) do
      :ok -> Bm.Workspace.Verify.run(check, root, timeout, coordinator)
      {:error, sentence} -> %{"exit" => 126, "output" => sentence, "refused" => true}
    end
  end

  defp verified(state, result) do
    state = %{state | verify_pgid: nil}

    verify =
      case result do
        %{} = verify -> verify
        other -> %{"exit" => nil, "output" => "verification crashed: #{inspect(other)}"}
      end

    case reattribute_after_verify(state) do
      {:ok, changes} -> verified_outcome(state, verify, changes)
      {:error, attrs} -> finish(state, :held, Map.put(attrs, :verify, verify))
    end
  end

  defp verified_outcome(state, verify, changes) do
    cond do
      state.cancel? ->
        finish(state, :cancelled, Map.put(changes, :verify, verify))

      verify["exit"] == 0 and check_passed?(verify) ->
        maybe_review(state, verify, changes)

      # A goal run's task check is written by BM's own planner, so its failure is a planning
      # error, not the user's to decide: revert and let the planner re-plan (decision D23).
      verify["exit"] == 0 and state.run.planner != nil ->
        revert_for_replan(state, verify, changes)

      verify["exit"] == 0 ->
        error = if verify["check"]["timeout"], do: "check_timeout", else: "check_failed"
        finish(state, :held, Map.merge(changes, %{verify: verify, error: error}))

      verify["timeout"] ->
        finish(state, :held, Map.merge(changes, %{verify: verify, error: "verify_timeout"}))

      true ->
        finish(state, :held, Map.merge(changes, %{verify: verify, error: "verify_failed"}))
    end
  end

  # The workspace verify command passed but the planner's check did not. The attempt fails (so
  # its task is reported to the planner as failed), then its changes are reverted, but only if
  # the files still hold exactly what the attempt left; otherwise it stays held for the user,
  # as before.
  defp revert_for_replan(state, verify, changes, reason \\ nil) do
    check = verify["check"] || %{}
    command = state.task.check

    reason =
      cond do
        reason -> reason
        check["timeout"] -> "the task's check `#{command}` timed out"
        true -> "the task's check `#{command}` exited #{check["exit"]}"
      end

    known = workers_paths(state)
    state = finish(state, :failed, Map.merge(changes, %{verify: verify, error: reason}))
    attempt = Runs.get_attempt!(state.attempt.id)
    # Only the worker's own writes go back (D33): another changed file may be the user's edit
    # made meanwhile, which a revert would lose with nobody asked. It stays and is named.
    {revert, left} = Enum.split_with(attempt.actual_writes, &(&1["path"] in known))
    left = Enum.map(left, & &1["path"])

    with [_ | _] <- revert,
         :ok <- Git.restore(state.root, revert, attempt.tree_before, attempt.tree_after),
         {:ok, attempt} <-
           Runs.transition_attempt(
             attempt,
             :reverted,
             auto_revert_note(attempt, reason, left)
           ) do
      broadcast_attempt(%{state | attempt: attempt, lane: :free})
    else
      # Nothing to revert: the lane is already free.
      [] ->
        state

      error ->
        Logger.warning(
          "attempt #{attempt.id}: not reverted after a failed check: #{inspect(error)}"
        )

        attempt =
          Runs.update_attempt_fields(attempt, %{
            error: reason <> "; files changed since, so BM did not revert them"
          })

        broadcast_attempt(%{state | attempt: attempt})
    end
  end

  # Paths the worker is known to have written: its declared writes, its edit/write calls and the
  # files its bash commands named (plan 36.6, D33).
  defp workers_paths(state),
    do: MapSet.union(MapSet.new(state.task.writes || []), state.touched)

  defp auto_revert_note(attempt, reason, []) do
    %{
      flags: attempt.flags ++ ["auto_reverted"],
      error: reason <> "; BM reverted its changes for a re-plan"
    }
  end

  defp auto_revert_note(attempt, reason, left) do
    %{
      flags: attempt.flags ++ ["auto_reverted", "files_left"],
      error:
        reason <>
          "; BM reverted the worker's changes for a re-plan and left #{Enum.join(left, ", ")} " <>
          "as #{if length(left) == 1, do: "it is", else: "they are"} (not known to be the " <>
          "worker's; maybe yours). Versions from before the attempt: " <>
          "git show #{String.slice(attempt.tree_before, 0, 12)}:<path>"
    }
  end

  ## Review (14.1, D25)

  # In a goal run, a change that passed verification is reviewed before it is accepted, unless
  # the workspace turned review off (settings "review": false).
  defp maybe_review(state, verify, changes) do
    attempt = Runs.get_attempt!(state.attempt.id)
    writes = Map.get(changes, :actual_writes, attempt.actual_writes)

    if state.run.planner != nil and writes != [] and state.workspace.settings["review"] != false do
      tree_after = Map.get(changes, :tree_after, attempt.tree_after)
      diff = review_diff(state.root, attempt.tree_before, tree_after, writes)
      deps = Runs.dependency_context(state.task)

      prompt =
        if is_function(state.config.review_prompt, 4),
          do: state.config.review_prompt.(state.task, deps, diff, state.run.goal),
          else: state.config.review_prompt.(state.task, deps, diff)

      agent_id = "review-#{attempt.id}"
      root = state.root
      owned = user_owned(state)

      state = %{state | phase: :reviewing, pending_review: {verify, changes, agent_id}}

      state
      |> start_job(:review, fn -> Bm.Review.run(agent_id, root, prompt, owned) end)
      |> broadcast_attempt()
    else
      checkpoint(state, verify, changes)
    end
  end

  @max_review_diff 20_000

  defp review_diff(root, before, after_tree, writes) do
    {text, left} =
      Enum.reduce(writes, {"", 0}, fn %{"path" => path}, {acc, left} ->
        cond do
          byte_size(acc) >= @max_review_diff ->
            {acc, left + 1}

          true ->
            diff =
              case Git.file_diff(root, before, after_tree, path) do
                {:ok, text} -> text
                {:error, _} -> "(no diff for #{path})"
              end

            {acc <> diff <> "\n", left}
        end
      end)

    text = String.slice(text, 0, @max_review_diff)
    if left > 0, do: text <> "\n(… #{left} more files not shown)", else: text
  end

  defp job_done_review(state, result) do
    {verify, changes, _agent_id} = state.pending_review
    state = %{state | pending_review: nil}

    # The reviewer runs commands to probe edge cases (18.1); it must not change files.
    case changed_during_review(state, changes) do
      :unchanged ->
        review_outcome(state, verify, changes, result)

      {:changed, paths, changes} ->
        state = add_review_spend(state, review_cost(result))
        list = Enum.join(paths, ", ")

        review = %{
          "verdict" => "invalid",
          "reason" => "files changed during the review: #{list}",
          "commands" => review_commands(result)
        }

        finish(
          state,
          :held,
          Map.merge(changes, %{
            verify: Map.put(verify, "review", review),
            error: "files changed during the review (the reviewer must not change files): #{list}"
          })
        )

      {:error, reason} ->
        state = add_review_spend(state, review_cost(result))
        error = "snapshot after the review failed: #{inspect(reason)}"
        finish(state, :held, Map.merge(changes, %{verify: verify, error: error}))
    end
  end

  defp review_cost({:ok, %{cost: cost}}), do: cost
  defp review_cost(_result), do: 0.0

  # The reviewer's bash commands and the policy's answers (plan 19.1).
  defp review_commands({:ok, %{commands: commands}}), do: commands
  defp review_commands(_result), do: []

  # Compares the workspace with the tree the reviewer was shown. Like the verify command's
  # changes (reattribute_after_verify), whatever changed becomes part of the attempt, so Keep
  # checkpoints what is on disk and Revert also undoes the review's changes.
  defp changed_during_review(state, changes) do
    attempt = Runs.get_attempt!(state.attempt.id)
    reviewed = Map.get(changes, :tree_after, attempt.tree_after)

    with true <- is_binary(reviewed) || {:error, :no_reviewed_tree},
         {:ok, tree} <- Git.snapshot(state.root),
         {:ok, by_review} <- Git.diff(state.root, reviewed, tree),
         {:ok, entries} <- Git.diff(state.root, attempt.tree_before, tree) do
      paths = Enum.map(by_review, & &1.path)
      owned? = Enum.any?(paths, &(&1 in user_owned(state)))

      flags =
        Map.get(changes, :flags, attempt.flags)
        |> Kernel.++(["reviewer_wrote"])
        |> Kernel.++(if owned?, do: ["user_owned_writes"], else: [])

      if paths == [] do
        :unchanged
      else
        attrs = %{
          tree_after: tree,
          actual_writes: Enum.map(entries, &write_entry/1),
          flags: flags
        }

        {:changed, paths, Map.merge(changes, attrs)}
      end
    end
  end

  defp review_outcome(state, verify, changes, result) do
    case result do
      {:ok, %{verdict: verdict, reason: reason, cost: cost}} ->
        state = add_review_spend(state, cost)

        review = %{
          "verdict" => Atom.to_string(verdict),
          "reason" => reason,
          "cost" => cost,
          "commands" => review_commands(result)
        }

        verify = Map.put(verify, "review", review)

        cond do
          state.cancel? ->
            finish(state, :cancelled, Map.put(changes, :verify, verify))

          verdict == :approve ->
            checkpoint(state, verify, changes)

          true ->
            revert_for_replan(
              state,
              verify,
              changes,
              "the reviewer rejected the change: #{String.trim_trailing(reason, ".")}"
            )
        end

      error ->
        if state.cancel? do
          finish(state, :cancelled, Map.put(changes, :verify, verify))
        else
          # The reviewer could not run: verification passed, so the change is accepted and
          # flagged as not reviewed rather than blocked.
          Logger.warning("attempt #{state.attempt.id}: review skipped: #{inspect(error)}")
          review = %{"verdict" => "skipped", "reason" => inspect(error)}
          flags = Map.get(changes, :flags, Runs.get_attempt!(state.attempt.id).flags)
          changes = Map.put(changes, :flags, flags ++ ["not_reviewed"])
          checkpoint(state, Map.put(verify, "review", review), changes)
        end
    end
  end

  defp add_review_spend(state, cost) when is_number(cost) and cost > 0 do
    run = Runs.add_spend(state.run, cost, 0)
    broadcast_run(state, run)
    %{state | run: run}
  end

  defp add_review_spend(state, _cost), do: state

  defp check_passed?(%{"check" => %{"exit" => 0}}), do: true
  defp check_passed?(%{"check" => _failed}), do: false
  defp check_passed?(_verify), do: true

  # The verify command may change files itself (formatters, generators). Those changes become
  # part of the attempt and of its checkpoint; changes to the user's files hold the lane.
  defp reattribute_after_verify(state) do
    attempt = Runs.get_attempt!(state.attempt.id)

    with {:ok, tree} <- Git.snapshot(state.root),
         {:ok, by_verify} <- Git.diff(state.root, attempt.tree_after, tree),
         {:ok, entries} <- Git.diff(state.root, attempt.tree_before, tree) do
      touched = for entry <- by_verify, entry.path in user_owned(state), do: entry.path

      changes =
        if by_verify == [],
          do: %{},
          else: %{
            tree_after: tree,
            actual_writes: Enum.map(entries, &write_entry/1),
            flags: attempt.flags ++ ["verify_changed_files"]
          }

      if touched == [] do
        {:ok, changes}
      else
        error = "verification changed the user's uncommitted files: #{Enum.join(touched, ", ")}"
        flags = Map.get(changes, :flags, attempt.flags) ++ ["user_owned_writes"]
        {:error, Map.merge(changes, %{error: error, flags: flags})}
      end
    else
      error -> {:error, %{error: "snapshot after verification failed: #{inspect(error)}"}}
    end
  end

  defp write_entry(entry), do: %{"path" => entry.path, "status" => Atom.to_string(entry.status)}

  ## Checkpoint and completion (4.8)

  defp checkpoint(state, verify, changes) do
    attempt = Runs.get_attempt!(state.attempt.id)
    attempt = %{attempt | tree_after: Map.get(changes, :tree_after, attempt.tree_after)}

    case record_checkpoint(state, attempt, "verified") do
      {:ok, ref} ->
        finish(state, :accepted, Map.merge(changes, %{verify: verify, checkpoint_ref: ref}))

      {:error, reason} ->
        error = "checkpoint failed: #{inspect(reason)}"
        finish(state, :held, Map.merge(changes, %{verify: verify, error: error}))
    end
  end

  defp record_checkpoint(state, attempt, kind) do
    previous =
      state.run
      |> Runs.list_run_attempts()
      |> Enum.find_value(& &1.checkpoint_ref)

    parent = if previous, do: Git.rev_parse(state.root, previous), else: Git.head(state.root)

    number =
      state.run |> Runs.list_run_attempts() |> Enum.count(& &1.checkpoint_ref) |> Kernel.+(1)

    ref = "refs/bm/runs/#{state.run.id}/#{number}"

    message =
      "BM run #{state.run.id}, task #{state.task.key}, attempt #{attempt.number} (#{kind})"

    with {:ok, _commit} <- Git.checkpoint(state.root, attempt.tree_after, parent, ref, message),
         do: {:ok, ref}
  end

  # Ends the current attempt in `status`; the lane is held if the attempt left changes that
  # were not accepted.
  defp finish(state, status, attrs) do
    state = drop_approvals(state)
    attempt = Runs.get_attempt!(state.attempt.id)

    attrs =
      if status == :cancelled and state.cancel_reason,
        do: Map.put_new(attrs, :error, "cancelled by BM: #{state.cancel_reason}"),
        else: attrs

    attempt =
      case Runs.transition_attempt(attempt, status, attrs) do
        {:ok, attempt} ->
          attempt

        # Someone else moved it first: the task follows what is stored, not this outcome
        # (plan 36.13: a task could read "accepted" while its attempt was not).
        {:error, reason} ->
          Logger.error(
            "attempt #{attempt.id}: #{attempt.status} -> #{status}: #{inspect(reason)}"
          )

          Runs.get_attempt!(attempt.id)
      end

    task =
      case task_status(attempt.status) do
        nil ->
          state.task

        task_status ->
          {:ok, task} = Runs.update_task_status(state.task, task_status)
          task
      end

    lane =
      if status != :accepted and attempt.actual_writes != [],
        do: {:held, attempt.id},
        else: :free

    broadcast_attempt(%{
      state
      | attempt: attempt,
        task: task,
        lane: lane,
        phase: nil,
        agent_id: nil,
        assignment: nil,
        cancel?: false,
        cancel_reason: nil
    })
  end

  defp task_status(:accepted), do: :accepted
  defp task_status(:cancelled), do: :cancelled
  defp task_status(status) when status in [:failed, :held, :needs_reconciliation], do: :failed
  # Still in flight (a move that failed): the task stays as it is.
  defp task_status(_status), do: nil

  ## Keep (4.8)

  defp keep_attempt(state, %Attempt{status: :held} = attempt) do
    state = %{state | task: Runs.get_task!(attempt.task_id)}

    attrs =
      case record_checkpoint(state, attempt, "kept, unverified") do
        {:ok, ref} -> %{checkpoint_ref: ref, flags: attempt.flags ++ ["kept"]}
        {:error, _} -> %{flags: attempt.flags ++ ["kept"]}
      end

    {:ok, attempt} = Runs.transition_attempt(attempt, :accepted, attrs)
    {:ok, task} = Runs.update_task_status(state.task, :accepted)
    broadcast_attempt(%{state | attempt: attempt, task: task, lane: :free})
  end

  # A failed, cancelled or interrupted attempt's changes stay in the workspace; the attempt keeps
  # its status.
  defp keep_attempt(state, attempt) do
    {:ok, attempt} = Runs.add_attempt_flag(attempt, "kept")
    broadcast_attempt(resume_if_reconciled(%{state | attempt: attempt, lane: :free}))
  end

  ## Revert (5.3)

  defp revert_latest(%{run: nil}), do: {:error, :nothing_to_revert}

  defp revert_latest(state) do
    run = Runs.get_run!(state.run.id)

    case Runs.list_run_attempts(run) do
      [%Attempt{status: :reverted} | _] ->
        {:error, :nothing_to_revert}

      [%Attempt{actual_writes: [_ | _], tree_before: from, tree_after: expected} = attempt | _]
      when is_binary(from) and is_binary(expected) ->
        cond do
          not Attempt.allowed?(attempt.status, :reverted) ->
            {:error, {:not_revertable, attempt.status}}

          # An accepted change in an active goal run: the revert could land inside a planner
          # turn, which BM reads as the planner changing files (D28). A held attempt waits for
          # exactly this decision.
          run.planner != nil and run.status == :active and state.lane != {:held, attempt.id} ->
            {:error, :run_not_paused}

          true ->
            restore_attempt(%{state | run: run}, attempt)
        end

      _ ->
        {:error, :nothing_to_revert}
    end
  end

  defp restore_attempt(state, attempt) do
    left = left_for_user(attempt, run_user_owned(state.run))
    entries = revertible_writes(attempt, left)
    was_accepted? = attempt.status == :accepted

    with :ok <- Git.restore(state.root, entries, attempt.tree_before, attempt.tree_after),
         {:ok, attempt} <-
           Runs.transition_attempt(attempt, :reverted, note_left(%{}, attempt, left)) do
      {:ok, task} = attempt.task_id |> Runs.get_task!() |> Runs.update_task_status(:cancelled)
      # A goal run's planner already heard this task was accepted: it hears again (as 23.1).
      if was_accepted? and state.run.planner, do: Runs.drop_delivery(task)
      # BM's own change outside an attempt: not the user's at the next admission (13.1). Undo
      # recorded an older known tree that would otherwise still count.
      run =
        if state.run.status in [:active, :paused] do
          {:ok, run} = remember_workspace(state.root, state.run)
          run
        else
          state.run
        end

      state = %{state | run: run, attempt: attempt, task: task, lane: :free}
      {:ok, broadcast_attempt(resume_if_reconciled(state))}
    end
  end

  # A run paused by recovery resumes once no interrupted attempt waits for the user. A goal run
  # only while this coordinator still watches its planner (just the coordinator restarted): a
  # planner the user paused (unwatched at once, though it may take seconds to stop) or one lost
  # with BM is not, and the run waits for Resume planning, which starts a new one. Resumed
  # without it, the run sat "active" with nothing to schedule its tasks, and a run the user had
  # paused came back by itself.
  defp resume_if_reconciled(%{run: %{id: id}} = state) do
    run = Runs.get_run!(id)

    waiting? =
      run
      |> Runs.list_run_attempts()
      |> Enum.any?(&(&1.status == :needs_reconciliation and "kept" not in &1.flags))

    planner_gone? =
      run.planner != nil and
        (state.planner_ref == nil or Bm.Workspace.Planner.whereis(id) == nil)

    case run do
      %{status: :paused} when not waiting? and not planner_gone? ->
        run = stored(Runs.resume_run(run), run)
        %{state | run: run}

      run ->
        %{state | run: run}
    end
  end

  ## Cancel (4.9)

  # `reason`: nil when the user cancels; "budget", "stall" or "max_duration" when BM does.
  defp request_cancel(%{cancel?: true} = state, _reason), do: state

  defp request_cancel(state, reason) do
    state = %{state | cancel?: true, cancel_reason: reason}

    case state.phase do
      # Handled when pi has started (job_done :start) or stopped (attribute).
      phase when phase in [:starting, :stopping] ->
        state

      :running ->
        stop_worker(state)

      :settling ->
        stop_worker(state)

      phase when phase in [:verifying, :baseline] ->
        tap(state, &(&1.verify_pgid && Bm.Proc.terminate_groups([&1.verify_pgid])))

      # Stopping the reviewer's session ends its job; job_done_review sees cancel?.
      :reviewing ->
        {_verify, _changes, agent_id} = state.pending_review
        Task.start(fn -> Bm.Pi.stop(agent_id) end)
        state
    end
  end

  ## Approvals (24.1)

  # Answers pi and forgets the approval; the silence clock starts again from the answer.
  defp reply_approval(state, dialog_id, reply) do
    {approval, approvals} = Map.pop(state.approvals, dialog_id)
    Process.cancel_timer(approval.timer)
    if state.agent_id, do: Bm.Pi.respond(state.agent_id, dialog_id, reply)

    state
    |> Map.put(:approvals, approvals)
    |> Map.put(:last_event_at, now())
    |> broadcast_approvals()
  end

  # The attempt ended: its pi session and its questions are gone.
  defp drop_approvals(state) do
    case Map.get(state, :approvals, %{}) do
      approvals when approvals == %{} ->
        state

      approvals ->
        Enum.each(approvals, fn {_id, approval} -> Process.cancel_timer(approval.timer) end)
        broadcast_approvals(Map.put(state, :approvals, %{}))
    end
  end

  defp approval_list(state) do
    state
    |> Map.get(:approvals, %{})
    |> Map.values()
    |> Enum.sort_by(& &1.since, DateTime)
    |> Enum.map(&Map.delete(&1, :timer))
  end

  defp broadcast_approvals(state) do
    Phoenix.PubSub.broadcast(
      Bm.PubSub,
      topic(state.root),
      {:workspace, state.root, {:approvals, state.run && state.run.id, approval_list(state)}}
    )

    state
  end

  ## Shutdown

  @impl true
  def terminate(_reason, state) do
    if state.agent_id, do: Bm.Pi.stop(state.agent_id)
    if state.verify_pgid, do: Bm.Proc.terminate_groups([state.verify_pgid])
    :ok
  end

  defp broadcast_attempt(state) do
    Phoenix.PubSub.broadcast(
      Bm.PubSub,
      topic(state.root),
      {:workspace, state.root, {:attempt, state.attempt, state.lane}}
    )

    state
  end
end
