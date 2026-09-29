defmodule Bm.Workspace.Coordinator do
  @moduledoc """
  One process per checkout (docs/ARCHITECTURE.md §7). It owns the workspace's **mutation lane**:
  at most one attempt runs at a time (decision D5), and the lane stays **held** after an attempt
  that left changes BM could not accept, until the user chooses Keep (or Revert, phase 5).

  An attempt goes through these phases:

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
    prompt: &Bm.Prompts.worker/1
  ]

  @output_tail 4_096

  ## API

  @doc """
  Starts the coordinator for the checkout at `path` (its top level) unless it runs already.
  Options (first start only): `:settle_interval`, `:settle_timeout`, `:verify_timeout` (ms) and
  `:prompt` (a function from the task to the worker prompt).
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
  optional `:key`), optional `:verify_command` (saved on the workspace) and `:run_goal`.
  Returns `{:ok, attempt}` once admitted; the attempt continues asynchronously.
  """
  def run_task(path, attrs), do: call(path, {:run_task, Map.new(attrs)})

  @doc "Lane, phase, run and current attempt."
  def state(path), do: call(path, :state)

  @doc "Cancels the running attempt. Changes it made stay and hold the lane."
  def cancel(path), do: call(path, :cancel)

  @doc "Accepts the held attempt's changes as they are (recorded as unverified) and frees the lane."
  def keep(path), do: call(path, :keep)

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
      verify_pgid: nil
    }

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

        %{state | run: run, lane: if(held, do: {:held, held.id}, else: :free)}
    end
  end

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

  def handle_call({:run_task, attrs}, _from, state) do
    case admit(state, attrs) do
      {:ok, state} -> {:reply, {:ok, state.attempt}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cancel, _from, %{phase: nil} = state),
    do: {:reply, {:error, :nothing_running}, state}

  def handle_call(:cancel, _from, state), do: {:reply, :ok, request_cancel(state)}

  def handle_call(:keep, _from, %{lane: {:held, attempt_id}} = state) do
    {:reply, :ok, keep_attempt(state, Runs.get_attempt!(attempt_id))}
  end

  def handle_call(:keep, _from, state), do: {:reply, {:error, :nothing_held}, state}

  ## Admission (4.4)

  defp admit(state, attrs) do
    with {:ok, workspace} <- maybe_set_verify_command(state.workspace, attrs),
         :ok <- if(workspace.verify_command, do: :ok, else: {:error, :no_verify_command}),
         {:ok, run} <- ensure_run(state, attrs),
         {:ok, task} <- Runs.create_task(run, task_attrs(run, attrs)),
         {:ok, attempt} <- Runs.create_attempt(task, %{role: role(task)}),
         {:ok, tree_before} <- Git.snapshot(state.root),
         {:ok, attempt} <-
           Runs.transition_attempt(attempt, :admitted, %{tree_before: tree_before}),
         {:ok, task} <- Runs.update_task_status(task, :running) do
      agent_id = "attempt-#{attempt.id}"
      Bm.Pi.subscribe(agent_id)

      state = %{
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
          flags: [],
          assignment: nil
      }

      coordinator = self()
      root = state.root
      role = attempt.role

      state =
        start_job(state, :start, fn ->
          Profile.start(agent_id, role, owner: coordinator, cwd: root)
        end)

      {:ok, broadcast_attempt(state)}
    end
  end

  defp maybe_set_verify_command(workspace, %{verify_command: command}) when is_binary(command),
    do: Runs.update_workspace(workspace, %{verify_command: command})

  defp maybe_set_verify_command(workspace, _attrs), do: {:ok, workspace}

  defp ensure_run(%{run: %{status: :active} = run}, _attrs), do: {:ok, run}
  defp ensure_run(%{run: %{status: :paused}}, _attrs), do: {:error, :run_paused}

  defp ensure_run(state, attrs) do
    with {:ok, baseline} <- Git.baseline(state.root) do
      Runs.start_run(state.workspace, %{
        goal: attrs[:run_goal] || attrs[:title] || "Task",
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
    %Task{ref: ref} = Task.Supervisor.async_nolink(Bm.TaskSupervisor, fun)
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

  # The worker's pi adapter died: settle with what we know.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{agent_ref: ref} = state) do
    state = %{state | agent_ref: nil, flags: ["agent_down" | state.flags]}
    {:noreply, if(state.phase == :running, do: begin_settling(state), else: state)}
  end

  ## Worker events and requests (4.5, 4.6)

  def handle_info({:pi, id, :status, %{status: :running}}, %{agent_id: id} = state),
    do: {:noreply, %{state | seen_running?: true}}

  def handle_info(
        {:pi, id, :status, %{status: :idle}},
        %{agent_id: id, phase: :running, seen_running?: true} = state
      ),
      do: {:noreply, begin_settling(state)}

  def handle_info(
        {:pi, id, _event, %{status: :exited}},
        %{agent_id: id, phase: :running} = state
      ),
      do: {:noreply, begin_settling(%{state | flags: ["pi_exited" | state.flags]})}

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

  def handle_info(:settle_check, %{phase: :settling} = state), do: {:noreply, settle_check(state)}
  def handle_info(:settle_check, state), do: {:noreply, state}

  def handle_info({:verify_started, pgid}, %{phase: :verifying} = state) do
    if state.cancel?, do: Bm.Proc.terminate_groups([pgid])
    {:noreply, %{state | verify_pgid: pgid}}
  end

  def handle_info(_message, state), do: {:noreply, state}

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
    ctx = %{root: state.root, user_owned: user_owned(state)}

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

  defp job_done(state, :start, {:ok, _report}) do
    summary = Bm.Pi.snapshot(state.agent_id).summary
    [{agent_pid, _}] = Registry.lookup(Bm.Pi.Registry, state.agent_id)

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

    state = broadcast_attempt(%{state | attempt: attempt, phase: :running})

    cond do
      state.cancel? ->
        stop_worker(state)

      Bm.Pi.prompt(state.agent_id, state.config.prompt.(state.task)) == :ok ->
        state

      true ->
        stop_worker(%{state | flags: ["prompt_failed" | state.flags]})
    end
  end

  defp job_done(state, :start, error) do
    Bm.Pi.unsubscribe(state.agent_id)

    reason =
      case error do
        {:error, reason} -> reason
        other -> other
      end

    finish(state, :failed, %{error: "worker did not start: #{inspect(reason)}"})
  end

  defp job_done(state, :stop, _result), do: stopped(state)
  defp job_done(state, :verify, result), do: verified(state, result)

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
      writes = Enum.map(entries, &%{"path" => &1.path, "status" => Atom.to_string(&1.status)})
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
    timeout = state.config.verify_timeout

    start_job(state, :verify, fn -> run_verify(coordinator, root, command, timeout) end)
  end

  @doc false
  # Runs `command` as the leader of its own process group; ends the whole group afterwards.
  def run_verify(coordinator, root, command, timeout) do
    {exe, args} = Bm.Proc.launch_args("/bin/sh", ["-c", command])

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: root
      ])

    {:os_pid, pgid} = Port.info(port, :os_pid)
    send(coordinator, {:verify_started, pgid})
    deadline = System.monotonic_time(:millisecond) + timeout
    result = collect_output(port, "", deadline)
    Bm.Proc.terminate_groups([pgid], 500)
    result
  end

  defp collect_output(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect_output(port, tail(output <> data), deadline)
      {^port, {:exit_status, status}} -> %{"exit" => status, "output" => output}
    after
      remaining ->
        Port.close(port)
        %{"exit" => nil, "timeout" => true, "output" => output}
    end
  end

  defp tail(output) when byte_size(output) <= @output_tail, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_tail, @output_tail)

  defp verified(state, result) do
    state = %{state | verify_pgid: nil}

    verify =
      case result do
        %{} = verify -> verify
        other -> %{"exit" => nil, "output" => "verification crashed: #{inspect(other)}"}
      end

    cond do
      state.cancel? ->
        finish(state, :cancelled, %{verify: verify})

      verify["exit"] == 0 ->
        checkpoint(state, verify)

      verify["timeout"] ->
        finish(state, :held, %{verify: verify, error: "verify_timeout"})

      true ->
        finish(state, :held, %{verify: verify, error: "verify_failed"})
    end
  end

  ## Checkpoint and completion (4.8)

  defp checkpoint(state, verify) do
    attempt = Runs.get_attempt!(state.attempt.id)

    case record_checkpoint(state, attempt, "verified") do
      {:ok, ref} ->
        finish(state, :accepted, %{verify: verify, checkpoint_ref: ref})

      {:error, reason} ->
        finish(state, :held, %{verify: verify, error: "checkpoint failed: #{inspect(reason)}"})
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
        cancel?: false
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

  # A failed or cancelled attempt's changes stay in the workspace; the attempt keeps its status.
  defp keep_attempt(state, attempt) do
    {:ok, attempt} = Runs.add_attempt_flag(attempt, "kept")
    broadcast_attempt(%{state | attempt: attempt, lane: :free})
  end

  ## Cancel (4.9)

  defp request_cancel(state) do
    state = %{state | cancel?: true}

    case state.phase do
      # Handled when pi has started (job_done :start) or stopped (attribute).
      phase when phase in [:starting, :stopping] -> state
      :running -> stop_worker(state)
      :settling -> stop_worker(state)
      :verifying -> tap(state, &(&1.verify_pgid && Bm.Proc.terminate_groups([&1.verify_pgid])))
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
