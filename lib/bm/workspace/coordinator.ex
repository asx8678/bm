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
    prompt: &Bm.Prompts.worker/2
  ]

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
  def run_task(path, attrs), do: call(path, {:run_task, Map.new(attrs)})

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

  @doc "Pauses the run `run_id` with `reason` (the planner lost or changed files)."
  def pause_run(path, run_id, reason), do: call(path, {:pause_run, run_id, reason})

  @doc "Resumes planning of the paused goal run `run_id` in a new planner session."
  def resume_planning(path, run_id, planner_opts \\ []),
    do: call(path, {:resume_planning, run_id, planner_opts})

  @doc "Lane, phase, run and current attempt."
  def state(path), do: call(path, :state)

  @doc "Cancels the running attempt. Changes it made stay and hold the lane."
  def cancel(path), do: call(path, :cancel)

  @doc "Accepts the held attempt's changes as they are (recorded as unverified) and frees the lane."
  def keep(path), do: call(path, :keep)

  @doc """
  Reverts the run's latest attempt (held or not): its files go back to `tree_before`, only if
  they still hold what the attempt left. `{:error, {:changed_since, paths}}` changes nothing.
  """
  def revert(path), do: call(path, :revert)

  @doc """
  Finishes the workspace's run (`:done`), which releases the workspace: the next task starts a
  new run with a fresh baseline of the user's files. Refused while an attempt runs or the lane
  is held.
  """
  def finish_run(path), do: call(path, :finish_run)

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
      # Monitor of the goal run's planner process.
      planner_ref: nil
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
  def handle_call(:state, _from, state) do
    reply = %{
      lane: state.lane,
      phase: state.phase,
      run_id: state.run && state.run.id,
      attempt_id: state.attempt && state.attempt.id
    }

    {:reply, reply, state}
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
         {:ok, pid} <- start_planner(state, run, opts) do
      state = %{state | workspace: workspace, run: run, planner_ref: Process.monitor(pid)}
      broadcast_run(state, run)
      {:reply, {:ok, run}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:end_run, run_id, status, reason}, _from, %{run: %{id: run_id}} = state) do
    if state.phase == nil and state.lane == :free do
      run = Runs.get_run!(run_id)

      for task <- Runs.latest_tasks(run), task.status in [:queued, :running] do
        Runs.update_task_status(task, :cancelled)
      end

      {:ok, run} = Runs.finish_run(run, status, reason)
      if state.planner_ref, do: Process.demonitor(state.planner_ref, [:flush])
      broadcast_run(state, run)
      {:reply, {:ok, run}, %{state | run: nil, attempt: nil, task: nil, planner_ref: nil}}
    else
      {:reply, {:error, :lane_busy}, state}
    end
  end

  def handle_call({:end_run, _run_id, _status, _reason}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call({:pause_run, run_id, reason}, _from, %{run: %{id: run_id}} = state) do
    case Runs.get_run!(run_id) do
      %{status: :active} = run ->
        {:ok, run} = Runs.pause_run(run, reason)
        broadcast_run(state, run)
        {:reply, {:ok, run}, %{state | run: run}}

      run ->
        {:reply, {:ok, run}, state}
    end
  end

  def handle_call({:pause_run, _run_id, _reason}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call({:resume_planning, run_id, opts}, _from, %{run: %{id: run_id}} = state) do
    run = Runs.get_run!(run_id)

    cond do
      run.status != :paused or run.planner == nil ->
        {:reply, {:error, :not_resumable}, state}

      state.phase != nil or state.lane != :free ->
        {:reply, {:error, :lane_busy}, state}

      true ->
        {:ok, run} = Runs.resume_run(run)

        case start_planner(state, run, Keyword.put(opts, :resume, true)) do
          {:ok, pid} ->
            broadcast_run(state, run)
            {:reply, {:ok, run}, %{state | run: run, planner_ref: Process.monitor(pid)}}

          {:error, reason} ->
            {:ok, run} = Runs.pause_run(run, "the planner did not start: #{inspect(reason)}")
            {:reply, {:error, reason}, %{state | run: run}}
        end
    end
  end

  def handle_call({:resume_planning, _run_id, _opts}, _from, state),
    do: {:reply, {:error, :not_resumable}, state}

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

    {:ok, run} = Runs.finish_run(run, status, reason)
    broadcast_run(state, run)
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
        last_event_at: nil
    }
  end

  defp start_worker(state) do
    coordinator = self()
    %{root: root, agent_id: agent_id, attempt: %{role: role}} = state

    state =
      start_job(%{state | phase: :starting}, :start, fn ->
        Profile.start(agent_id, role, owner: coordinator, cwd: root)
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

  # A queued task of this run (the planner's), or a new one.
  defp admit_task(run, %{task_id: id}) do
    case Runs.get_task!(id) do
      %{run_id: run_id, status: :queued} = task when run_id == run.id -> {:ok, task}
      %{run_id: run_id} when run_id != run.id -> {:error, :run_not_active}
      %{status: status} -> {:error, {:task_not_queued, status}}
    end
  end

  defp admit_task(run, attrs), do: Runs.create_task(run, task_attrs(run, attrs))

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

  defp broadcast_run(state, run) do
    Phoenix.PubSub.broadcast(Bm.PubSub, topic(state.root), {:workspace, state.root, {:run, run}})
  end

  defp maybe_set_verify_command(workspace, %{verify_command: command}) when is_binary(command),
    do: Runs.update_workspace(workspace, %{verify_command: command})

  defp maybe_set_verify_command(workspace, _attrs), do: {:ok, workspace}

  defp ensure_run(%{run: %{status: :active} = run}, _attrs) do
    run = Runs.get_run!(run.id)
    if Runs.budget_exhausted?(run), do: {:error, :budget_exhausted}, else: {:ok, run}
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
        {:ok, run} = Runs.pause_run(run, "the planner stopped unexpectedly (#{inspect(reason)})")
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
      %{state | tool: summary[:tool], last_event_at: now()}
      |> track_spend(summary)
      |> enforce_budget()

    {:noreply, worker_event(state, event, summary)}
  end

  def handle_info({:pi, _id, _event, _summary}, state), do: {:noreply, state}

  def handle_info({:pi_request, id, request}, %{agent_id: id} = state) do
    {outcome, state} = handle_request(state, request)
    Bm.Pi.respond(id, request.dialog_id, outcome)
    {:noreply, state}
  end

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

  defp worker_event(state, _event, _summary), do: state

  ## Limits (5.1, 5.2)

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

      state.tool == nil and now() - state.last_event_at >= state.config.stall_timeout ->
        request_cancel(state, "stall")

      true ->
        schedule_limits_check(state)
    end
  end

  defp handle_request(state, request) do
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
    mode = if state.attempt.role == :reader, do: :read_only, else: :write
    ctx = %{root: state.root, user_owned: user_owned(state), mode: mode}

    case Bm.Policy.authorize(tool, payload["input"] || %{}, ctx) do
      :allow -> %{"ok" => true, "allow" => true}
      {:deny, reason} -> %{"ok" => true, "allow" => false, "reason" => reason}
    end
  end

  defp authorize(_state, _payload), do: %{"ok" => false, "error" => "malformed_authorize"}

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

  defp job_done(state, :stop, _result), do: stopped(state)
  defp job_done(state, :verify, result), do: verified(state, result)
  defp job_done(state, :baseline, result), do: baseline_verified(state, result)

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
      Bm.Pi.stop(agent_id)
      # Groups of an adapter that died without cleaning up.
      Bm.Proc.terminate_groups(orphans)
    end)
  end

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

  defp start_verification(state) do
    coordinator = self()
    root = state.root
    command = state.workspace.verify_command
    check = state.task.check
    timeout = state.config.verify_timeout

    # The task's check (plan 7.7) runs only after the workspace verify command passed.
    start_job(state, :verify, fn ->
      case Bm.Workspace.Verify.run(command, root, timeout, coordinator) do
        %{"exit" => 0} = verify when is_binary(check) ->
          Map.put(verify, "check", Bm.Workspace.Verify.run(check, root, timeout, coordinator))

        verify ->
          verify
      end
    end)
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
        checkpoint(state, verify, changes)

      verify["exit"] == 0 ->
        error = if verify["check"]["timeout"], do: "check_timeout", else: "check_failed"
        finish(state, :held, Map.merge(changes, %{verify: verify, error: error}))

      verify["timeout"] ->
        finish(state, :held, Map.merge(changes, %{verify: verify, error: "verify_timeout"}))

      true ->
        finish(state, :held, Map.merge(changes, %{verify: verify, error: "verify_failed"}))
    end
  end

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
    attempt = Runs.get_attempt!(state.attempt.id)

    attrs =
      if status == :cancelled and state.cancel_reason,
        do: Map.put_new(attrs, :error, "cancelled by BM: #{state.cancel_reason}"),
        else: attrs

    attempt =
      case Runs.transition_attempt(attempt, status, attrs) do
        {:ok, attempt} ->
          attempt

        {:error, reason} ->
          Logger.error(
            "attempt #{attempt.id}: #{attempt.status} -> #{status}: #{inspect(reason)}"
          )

          attempt
      end

    task_status =
      case status do
        :accepted -> :accepted
        :cancelled -> :cancelled
        _ -> :failed
      end

    {:ok, task} = Runs.update_task_status(state.task, task_status)

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
    case Runs.list_run_attempts(state.run) do
      [%Attempt{status: :reverted} | _] ->
        {:error, :nothing_to_revert}

      [%Attempt{actual_writes: [_ | _], tree_before: from, tree_after: expected} = attempt | _]
      when is_binary(from) and is_binary(expected) ->
        if Attempt.allowed?(attempt.status, :reverted),
          do: restore_attempt(state, attempt),
          else: {:error, {:not_revertable, attempt.status}}

      _ ->
        {:error, :nothing_to_revert}
    end
  end

  defp restore_attempt(state, attempt) do
    with :ok <-
           Git.restore(state.root, attempt.actual_writes, attempt.tree_before, attempt.tree_after),
         {:ok, attempt} <- Runs.transition_attempt(attempt, :reverted) do
      {:ok, task} = attempt.task_id |> Runs.get_task!() |> Runs.update_task_status(:cancelled)
      state = %{state | attempt: attempt, task: task, lane: :free}
      {:ok, broadcast_attempt(resume_if_reconciled(state))}
    end
  end

  # A run paused by recovery resumes once no interrupted attempt waits for the user.
  defp resume_if_reconciled(%{run: %{id: id}} = state) do
    run = Runs.get_run!(id)

    waiting? =
      run
      |> Runs.list_run_attempts()
      |> Enum.any?(&(&1.status == :needs_reconciliation and "kept" not in &1.flags))

    case run do
      %{status: :paused} when not waiting? ->
        {:ok, run} = Runs.resume_run(run)
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
    end
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
