defmodule Bm.Workspace.Planner do
  @moduledoc """
  The planner of one goal run (plan phase 7, decision D20). Started by the workspace coordinator
  (`Coordinator.start_goal/3`), which keeps owning the mutation lane and the attempts; this
  process owns the planner's pi session, validates its proposals, schedules the run's tasks and
  reports their results back.

  **Turns and the lane.** The planner takes a turn (the first prompt, a delivery, a reminder)
  only while the lane is free, and tasks are admitted only while the planner is idle. Planner
  and workers never run at the same time, so a snapshot before and after each planner turn shows
  exactly what the planner changed: any change pauses the run (the planner writes no code).

  **Proposals** (`bm:propose_task`, through `Bm.Bridge`) are checked by `Bm.Plan.validate/2`
  and stored as queued tasks; the reply says accepted or rejected with the reason.
  `bm:close_plan` closes planning. `bm:authorize` (the planner's read-only bash) is decided by
  `Bm.Policy` in read-only mode.

  **Scheduling** (`advance/1`), whenever the planner is idle and the lane is free:

    1. every ended task gets a delivery (received once, `Bm.Runs.receive_delivery/2`);
    2. a task that failed again after its one re-plan fails the run;
    3. results that need a decision (failed, blocked, cancelled) are delivered first;
    4. otherwise the oldest queued task whose dependencies are accepted is admitted;
    5. queued tasks whose dependency ended without success become blocked;
    6. accepted results are delivered in one batch when nothing else can run (end of a wave);
    7. with nothing left: a closed plan completes the run (done if every task was accepted);
       an open plan gets one reminder per wave, then `plan_timeout` fails the run.

  Each delivery reopens planning (a new wave). Limits: `max_rejections` per wave, `max_waves`,
  `plan_timeout`, `turn_timeout`, and the run's budget, which the planner's spend counts
  against.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Bm.Pi.Profile
  alias Bm.Runs
  alias Bm.Workspace.{Coordinator, Git}

  @defaults [
    prompt: &Bm.Prompts.planner/2,
    max_rejections: 5,
    max_waves: 5,
    plan_timeout: 5 * 60_000,
    turn_timeout: 15 * 60_000,
    # While idle, the planner re-checks the run this often: events can be missed (a restarted
    # coordinator, a recovery), and the lane state is the coordinator's.
    tick: 5_000
  ]

  @ended [:failed, :blocked, :cancelled]
  @max_log 60
  @max_log_text 2_000

  ## API

  @doc "Starts the planner of run `run_id` in the checkout `root` (called by the coordinator)."
  def start(run_id, root, opts \\ []) do
    spec = {__MODULE__, Keyword.merge(opts, run_id: run_id, root: root)}

    case DynamicSupervisor.start_child(Bm.Workspace.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def whereis(run_id) do
    case Registry.lookup(Bm.Workspace.Registry, {:planner, run_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Stops the planner of `run_id` and its pi session, if running."
  def stop(run_id) do
    case whereis(run_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Bm.Workspace.Supervisor, pid)
    end
  end

  @doc "Phase and counters, for tests and the run page."
  def state(run_id) do
    case whereis(run_id) do
      nil -> nil
      pid -> GenServer.call(pid, :state)
    end
  end

  @doc "The pi agent id of the planner session `session` of `run_id`."
  def agent_id(run_id, session), do: "planner-#{run_id}-#{session}"

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:run_id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Bm.Workspace.Registry, {:planner, run_id}}}
    )
  end

  ## Start

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    run_id = Keyword.fetch!(opts, :run_id)
    root = Keyword.fetch!(opts, :root)
    run = Runs.get_run!(run_id)
    session = (run.planner["session"] || 0) + 1
    agent_id = agent_id(run_id, session)

    {:ok, run} = Runs.update_run(run, %{planner: Map.put(run.planner, "session", session)})
    Coordinator.subscribe(root)
    Bm.Pi.subscribe(agent_id)

    state = %{
      run_id: run_id,
      root: root,
      goal: run.goal,
      resume?: Keyword.get(opts, :resume, false),
      config: Map.new(Keyword.merge(@defaults, Keyword.take(opts, Keyword.keys(@defaults)))),
      agent_id: agent_id,
      assignment: nil,
      # :starting | :busy (a turn runs) | :idle | :ending
      phase: :starting,
      job: nil,
      turn: 0,
      turn_tree: nil,
      seen_running?: false,
      spend_seen: %{confirmed: 0.0, unknown: 0},
      rejections: 0,
      counted: MapSet.new(),
      reminded?: false,
      plan_timer: nil,
      aborting?: false,
      # Set when a limit is hit during a turn: the run fails once the planner is idle.
      fail_reason: nil
    }

    coordinator = self()

    state =
      start_job(state, :start, fn ->
        Profile.start(agent_id, :planner, owner: coordinator, cwd: root)
      end)

    Process.send_after(self(), :tick, state.config.tick)
    broadcast(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, Map.take(state, [:phase, :turn, :rejections, :agent_id, :reminded?]), state}
  end

  ## Jobs

  defp start_job(state, kind, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(Bm.TaskSupervisor, fun)
    %{state | job: {ref, kind}}
  end

  @impl true
  def handle_info({ref, result}, %{job: {ref, kind}} = state) do
    Process.demonitor(ref, [:flush])
    job_done(%{state | job: nil}, kind, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job: {ref, kind}} = state) do
    job_done(%{state | job: nil}, kind, {:error, {:job_crashed, reason}})
  end

  ## pi events and requests

  def handle_info({:pi, id, event, summary}, %{agent_id: id} = state) do
    state = track_spend(state, summary)

    case {event, summary} do
      {:status, %{status: :running}} ->
        {:noreply, %{state | seen_running?: true}}

      {:status, %{status: :idle}} when state.phase == :busy and state.seen_running? ->
        turn_ended(state)

      {_event, %{status: :exited}} when state.phase in [:busy, :idle] ->
        pause(state, "the planner's pi process exited")

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:pi_request, id, request}, %{agent_id: id} = state) do
    {outcome, state} = handle_request(state, request)
    Bm.Pi.respond(id, request.dialog_id, outcome)

    if state.rejections > state.config.max_rejections do
      fail_after_turn(
        state,
        "the planner made more than #{state.config.max_rejections} invalid proposals in one wave"
      )
    else
      {:noreply, state}
    end
  end

  def handle_info({:pi_request, id, request}, state) do
    Bm.Pi.respond(id, request.dialog_id, %{"ok" => false, "error" => "not_assigned"})
    {:noreply, state}
  end

  ## Coordinator events: an attempt ended or the lane changed

  def handle_info({:workspace, _root, {:attempt, _attempt, _lane}}, %{phase: :idle} = state),
    do: advance(state)

  def handle_info({:workspace, _root, {:run, %{id: id, status: status}}}, %{run_id: id} = state)
      when status in [:done, :failed, :cancelled] do
    {:stop, :normal, %{state | phase: :ending}}
  end

  def handle_info({:workspace, _root, _event}, state), do: {:noreply, state}

  ## Timers

  def handle_info({:plan_timeout, turn}, %{turn: turn, phase: :idle} = state) do
    run = Runs.get_run!(state.run_id)

    if run.status == :active and run.plan_open,
      do: end_run(state, :failed, "the planner left the plan open"),
      else: {:noreply, state}
  end

  def handle_info({:turn_timeout, turn}, %{turn: turn, phase: :busy} = state) do
    fail_after_turn(
      abort(state),
      "a planner turn took longer than #{div(state.config.turn_timeout, 1000)} s"
    )
  end

  def handle_info(:advance, %{phase: :idle} = state), do: advance(state)

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.config.tick)
    if state.phase == :idle, do: advance(state), else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Bm.Pi.stop(state.agent_id)
    :ok
  end

  ## Start results

  defp job_done(state, :start, {:ok, _report}) do
    summary = Bm.Pi.snapshot(state.agent_id).summary
    run = Runs.get_run!(state.run_id)

    planner =
      Map.merge(run.planner, %{
        "agent_id" => state.agent_id,
        "pgid" => summary.pgid,
        "pgid_file" => summary.pgid_file,
        "boot_id" => Bm.Proc.boot_id()
      })

    {:ok, run} = Runs.update_run(run, %{planner: planner})
    state = %{state | assignment: %{session_epoch: summary.session_epoch}}
    context = prompt_context(run, state.root)

    text =
      if state.resume?,
        do: Bm.Prompts.planner_resume(run.goal, context, Runs.latest_tasks(run)),
        else: state.config.prompt.(run.goal, context)

    begin_turn(state, :prompt, text)
  end

  defp job_done(state, :start, error) do
    reason =
      case error do
        {:error, reason} -> reason
        other -> other
      end

    end_run(state, :failed, "the planner did not start: #{inspect(reason)}")
  end

  defp job_done(state, :abort, _result), do: {:noreply, state}

  defp prompt_context(run, root) do
    workspace = Runs.ensure_workspace(root) |> elem(1)

    %{
      root: root,
      verify_command: workspace.verify_command,
      user_owned: get_in(run.baseline, ["user_owned"]) || []
    }
  end

  ## Turns

  defp begin_turn(state, kind, text) do
    case Git.snapshot(state.root) do
      {:ok, tree} ->
        turn = state.turn + 1
        state = %{state | turn: turn, turn_tree: tree, phase: :busy, seen_running?: false}
        state = cancel_plan_timer(state)
        log(state, kind_label(kind), text)
        Process.send_after(self(), {:turn_timeout, turn}, state.config.turn_timeout)

        case Bm.Pi.prompt(state.agent_id, text) do
          :ok ->
            broadcast(state)
            {:noreply, state}

          error ->
            pause(state, "the planner did not take the prompt: #{inspect(error)}")
        end

      error ->
        pause(state, "snapshot before a planner turn failed: #{inspect(error)}")
    end
  end

  defp kind_label(:prompt), do: "prompt"
  defp kind_label(:delivery), do: "results"
  defp kind_label(:reminder), do: "reminder"

  defp turn_ended(state) do
    state = %{state | phase: :idle, seen_running?: false}
    log(state, "reply", last_reply(state.agent_id))

    with {:ok, tree} <- Git.snapshot(state.root),
         {:ok, entries} <- Git.diff(state.root, state.turn_tree, tree) do
      case entries do
        [] when is_binary(state.fail_reason) ->
          end_run(state, :failed, state.fail_reason)

        [] ->
          advance(state)

        entries ->
          paths = Enum.map_join(entries, ", ", & &1.path)
          pause(state, "the planner changed files, which it must not: #{paths}")
      end
    else
      error -> pause(state, "snapshot after a planner turn failed: #{inspect(error)}")
    end
  end

  defp last_reply(agent_id) do
    agent_id
    |> Bm.Pi.snapshot()
    |> Map.fetch!(:transcript)
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant, text: text} when text != "" -> text
      _ -> nil
    end)
  catch
    :exit, _ -> ""
  end

  ## Requests

  defp handle_request(state, request) do
    outcome =
      Bm.Bridge.handle(:planner, state.agent_id, request, state.assignment, fn request ->
        case request.op do
          "propose_task" -> propose(state, request.payload)
          "close_plan" -> close_plan(state, request.payload)
          "authorize" -> authorize(state, request.payload)
        end
      end)

    state =
      if outcome["status"] == "rejected" and not MapSet.member?(state.counted, request.request_id),
        do: %{
          state
          | rejections: state.rejections + 1,
            counted: MapSet.put(state.counted, request.request_id)
        },
        else: state

    {outcome, state}
  end

  defp propose(state, payload) do
    run = Runs.get_run!(state.run_id)

    ctx = %{
      tasks: Runs.list_tasks(run),
      user_owned: get_in(run.baseline, ["user_owned"]) || [],
      root: state.root,
      budget_left: run.budget_usd && run.budget_usd - run.spent_usd,
      plan_open: run.status == :active and run.plan_open
    }

    with {:ok, attrs} <- Bm.Plan.validate(payload, ctx),
         {:ok, task} <- Runs.create_task(run, attrs) do
      broadcast_task(state, task)
      %{"ok" => true, "status" => "accepted", "key" => task.key, "revision" => task.revision}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        %{
          "ok" => true,
          "status" => "rejected",
          "reason" => "BM could not store it: #{inspect(changeset.errors)}"
        }

      {:error, reason} ->
        %{"ok" => true, "status" => "rejected", "reason" => reason}
    end
  end

  defp close_plan(state, payload) do
    run = Runs.get_run!(state.run_id)
    summary = if is_binary(payload["summary"]), do: String.slice(payload["summary"], 0, 1_000)

    {:ok, run} =
      Runs.update_run(run, %{plan_open: false, planner: Map.put(run.planner, "summary", summary)})

    broadcast_run(state, run)
    %{"ok" => true, "status" => "closed"}
  end

  defp authorize(state, %{"tool" => tool} = payload) do
    run = Runs.get_run!(state.run_id)
    user_owned = get_in(run.baseline, ["user_owned"]) || []
    ctx = %{root: state.root, user_owned: user_owned, mode: :read_only}

    case Bm.Policy.authorize(tool, payload["input"] || %{}, ctx) do
      :allow -> %{"ok" => true, "allow" => true}
      {:deny, reason} -> %{"ok" => true, "allow" => false, "reason" => reason}
    end
  end

  defp authorize(_state, _payload), do: %{"ok" => false, "error" => "malformed_authorize"}

  ## Scheduling (7.4, 7.6, 7.8, 7.9)

  defp advance(%{phase: :idle} = state) do
    run = Runs.get_run!(state.run_id)

    cond do
      run.status != :active -> {:noreply, state}
      not lane_free?(state, run) -> {:noreply, state}
      true -> schedule(state, run)
    end
  end

  defp lane_free?(state, run) do
    case Coordinator.state(state.root) do
      %{lane: :free, phase: nil, run_id: run_id} ->
        run_id == run.id

      {:error, :not_started} ->
        # The coordinator died (it is :temporary); start it again. Its start-up recovery
        # leaves this run alone because this planner is alive, and it monitors us again.
        Coordinator.ensure_started(state.root)
        false

      _other ->
        false
    end
  catch
    :exit, _ -> false
  end

  defp schedule(state, run) do
    tasks = Runs.latest_tasks(run)
    by_key = Map.new(tasks, &{&1.key, &1})

    # 1. Every ended task revision is received once.
    delivered = MapSet.new(Runs.delivered_task_ids(run))

    for task <- Runs.list_tasks(run),
        task.status in [:accepted | @ended],
        not MapSet.member?(delivered, task.id) do
      Runs.receive_delivery(task, task.status)
    end

    pending = Runs.pending_deliveries(run)
    runnable = Enum.filter(tasks, &runnable?(&1, by_key))

    newly_blocked =
      Enum.filter(tasks, fn task ->
        task.status == :queued and
          Enum.any?(task.depends_on, &(by_key[&1] && by_key[&1].status in @ended))
      end)

    cond do
      # 2. One re-plan per failed task; a second failure ends the run.
      twice = Enum.find(tasks, &(&1.status == :failed and &1.revision > 1)) ->
        end_run(state, :failed, "task #{twice.key} failed again after its re-plan")

      # 3. Results that need the planner's decision go first.
      Enum.any?(pending, &(&1.status != :accepted)) ->
        deliver(state, run, pending, tasks)

      # 4. The next task whose dependencies are accepted.
      task = List.first(runnable) ->
        admit(state, run, task)

      # 5. Tasks behind a dependency that ended without success.
      newly_blocked != [] ->
        for task <- newly_blocked do
          {:ok, task} = Runs.update_task_status(task, :blocked)
          broadcast_task(state, task)
        end

        schedule(state, run)

      # 6. End of a wave: report the accepted results together.
      pending != [] ->
        deliver(state, run, pending, tasks)

      # 7. Nothing left to run or report.
      run.plan_open ->
        plan_left_open(state)

      true ->
        complete(state, tasks)
    end
  end

  defp runnable?(%{status: :queued, depends_on: deps}, by_key),
    do: Enum.all?(deps, &(by_key[&1] && by_key[&1].status == :accepted))

  defp runnable?(_task, _by_key), do: false

  defp admit(state, run, task) do
    if Runs.budget_exhausted?(run) do
      end_run(state, :failed, "the run's budget is spent")
    else
      case Coordinator.run_task(state.root, %{task_id: task.id}) do
        {:ok, _attempt} ->
          {:noreply, state}

        {:error, :lane_busy} ->
          {:noreply, state}

        {:error, :budget_exhausted} ->
          end_run(state, :failed, "the run's budget is spent")

        {:error, reason} ->
          pause(state, "BM could not start task #{task.key}: #{inspect(reason)}")
      end
    end
  end

  defp deliver(state, run, pending, tasks) do
    waves = run.planner["waves"] || 1

    cond do
      Runs.budget_exhausted?(run) ->
        end_run(state, :failed, "the run's budget is spent")

      waves >= state.config.max_waves ->
        end_run(state, :failed, "planning needed more than #{state.config.max_waves} waves")

      true ->
        results = Enum.map(pending, &result/1)
        queued = Enum.filter(tasks, &(&1.status == :queued))
        Runs.mark_delivered(pending)

        {:ok, run} =
          Runs.update_run(run, %{
            plan_open: true,
            planner: Map.put(run.planner, "waves", waves + 1)
          })

        broadcast_run(state, run)
        state = %{state | rejections: 0, reminded?: false}
        begin_turn(state, :delivery, Bm.Prompts.planner_delivery(results, queued))
    end
  end

  defp result(delivery) do
    task = delivery.task
    attempt = Runs.latest_attempt(task)
    verify = (attempt && attempt.verify) || %{}
    failed? = delivery.status != :accepted

    tail =
      if failed? do
        output = get_in(verify, ["check", "output"]) || verify["output"]

        if is_binary(output) and output != "",
          do: output |> String.slice(-600, 600) |> String.trim()
      end

    %{
      task: task,
      status: delivery.status,
      summary: attempt && attempt.result && attempt.result["summary"],
      writes: if(attempt, do: Enum.map(attempt.actual_writes, & &1["path"]), else: []),
      error: attempt && attempt.error,
      verify_tail: tail
    }
  end

  defp plan_left_open(%{reminded?: false} = state) do
    if Runs.budget_exhausted?(Runs.get_run!(state.run_id)),
      do: end_run(state, :failed, "the run's budget is spent"),
      else: begin_turn(%{state | reminded?: true}, :reminder, Bm.Prompts.planner_reminder())
  end

  defp plan_left_open(state) do
    ref = Process.send_after(self(), {:plan_timeout, state.turn}, state.config.plan_timeout)
    {:noreply, %{cancel_plan_timer(state) | plan_timer: ref}}
  end

  defp cancel_plan_timer(%{plan_timer: nil} = state), do: state

  defp cancel_plan_timer(state) do
    Process.cancel_timer(state.plan_timer)
    %{state | plan_timer: nil}
  end

  defp complete(state, tasks) do
    failed = Enum.reject(tasks, &(&1.status == :accepted))

    cond do
      tasks == [] ->
        end_run(state, :done, "the planner closed the plan without tasks")

      failed == [] ->
        end_run(state, :done, "all #{length(tasks)} tasks accepted")

      true ->
        keys = Enum.map_join(failed, ", ", &"#{&1.key} (#{&1.status})")
        end_run(state, :failed, "not every task succeeded: #{keys}")
    end
  end

  ## Ending, pausing, limits

  defp end_run(state, status, reason) do
    log(state, "end", "#{status}: #{reason}")

    case Coordinator.end_run(state.root, state.run_id, status, reason) do
      {:ok, _run} ->
        {:stop, :normal, %{state | phase: :ending}}

      {:error, :lane_busy} ->
        # An attempt is running or waits for the user's decision; try again when it ends.
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("planner #{state.run_id}: could not end the run: #{inspect(reason)}")
        {:stop, :normal, %{state | phase: :ending}}
    end
  end

  # Pauses the run for the user (Resume planning / Finish) and stops this planner session.
  defp pause(state, reason) do
    log(state, "paused", reason)
    Coordinator.pause_run(state.root, state.run_id, reason)
    {:stop, :normal, %{state | phase: :ending}}
  end

  # A limit hit during a turn: stop the model; the run fails when the turn has ended.
  defp fail_after_turn(%{phase: :busy} = state, reason),
    do: {:noreply, abort(%{state | fail_reason: state.fail_reason || reason})}

  defp fail_after_turn(state, reason), do: end_run(state, :failed, reason)

  defp abort(%{aborting?: true} = state), do: state

  defp abort(state) do
    agent_id = state.agent_id
    start_job(%{state | aborting?: true}, :abort, fn -> Bm.Pi.abort(agent_id) end)
  end

  ## Spend

  defp track_spend(state, %{spend: %{confirmed: confirmed, unknown: unknown}}) do
    seen = state.spend_seen
    delta = confirmed - seen.confirmed
    unknown_delta = unknown - seen.unknown

    if delta > 0 or unknown_delta > 0 do
      run = Runs.add_spend(Runs.get_run!(state.run_id), max(delta, 0.0), max(unknown_delta, 0))
      broadcast_run(state, run)
      state = %{state | spend_seen: %{confirmed: confirmed, unknown: unknown}}

      if Runs.budget_exhausted?(run) and state.phase == :busy,
        do: abort(state),
        else: state
    else
      state
    end
  end

  defp track_spend(state, _summary), do: state

  ## Log and broadcasts

  defp log(state, kind, text) when is_binary(text) do
    run = Runs.get_run!(state.run_id)

    entry = %{
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "kind" => kind,
      "text" => String.slice(text, 0, @max_log_text)
    }

    log = Enum.take((run.planner["log"] || []) ++ [entry], -@max_log)
    {:ok, run} = Runs.update_run(run, %{planner: Map.put(run.planner, "log", log)})
    broadcast_run(state, run)
  end

  defp log(_state, _kind, _text), do: :ok

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Bm.PubSub,
      Coordinator.topic(state.root),
      {:workspace, state.root, {:planner, state.run_id, %{phase: state.phase, turn: state.turn}}}
    )

    state
  end

  defp broadcast_run(state, run) do
    Phoenix.PubSub.broadcast(
      Bm.PubSub,
      Coordinator.topic(state.root),
      {:workspace, state.root, {:run, run}}
    )
  end

  defp broadcast_task(state, task) do
    Phoenix.PubSub.broadcast(
      Bm.PubSub,
      Coordinator.topic(state.root),
      {:workspace, state.root, {:task, task}}
    )
  end
end
