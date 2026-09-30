defmodule BmWeb.RunLive do
  @moduledoc """
  One run: its attempts with status, worker summary, flags, verification output and the diff of
  every file each attempt changed, updated live from the workspace coordinator. Actions depend on
  the workspace's lane: Stop while an attempt runs; Keep or Revert when an attempt waits for a
  decision; a next task, Revert of the last change, or Finish when the lane is free.

  A goal run (plan 8.1) also shows its planner (state, waves, summary, log) and its task list
  with dependencies and states; the planner picks the next task, so there is no next-task form,
  and a paused goal run offers Resume planning.
  """

  use BmWeb, :live_view

  import BmWeb.RunComponents

  alias Bm.Runs
  alias Bm.Workspace.{Coordinator, Git, Planner}
  alias BmWeb.RunGraph

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {id, ""} -> mount_run(Runs.get_run_with_workspace(id), socket)
      _ -> mount_run(nil, socket)
    end
  end

  defp mount_run(nil, socket) do
    {:ok, socket |> put_flash(:error, "No such run.") |> push_navigate(to: ~p"/")}
  end

  defp mount_run(run, socket) do
    root = run.workspace.path
    if connected?(socket), do: Coordinator.subscribe(root)
    attempts = Runs.list_run_attempts_with_tasks(run)

    {:ok,
     socket
     |> assign(
       page_title: "#{label(run)} · #{run.goal}",
       run: run,
       root: root,
       lane: lane(run),
       latest: List.last(attempts),
       form: to_form(%{"goal" => ""}, as: :next),
       goal_run?: run.planner != nil,
       planner_phase: planner_phase(run),
       # Live activity from pi: node id => data merged into the canvas; agents watched; the
       # running worker's agent and task key, and its current tool for the action bar.
       live: %{},
       watching: MapSet.new(),
       worker: nil,
       worker_tool: nil,
       checkpoints_pruned?: pruned?(run, root, attempts),
       graph: if(run.planner, do: RunGraph.build(run, Runs.latest_tasks(run)))
     )
     |> stream(:tasks, if(run.planner, do: Runs.list_tasks(run), else: []))
     |> stream(:attempts, Enum.map(attempts, &decorate(&1, root)))
     |> then(&if(connected?(&1), do: watch_live(&1, List.last(attempts)), else: &1))}
  end

  # A finished run whose checkpoint refs are gone (pruned after newer runs, see the coordinator).
  defp pruned?(%{status: status}, root, attempts) when status in [:done, :failed, :cancelled] do
    case Enum.find_value(attempts, & &1.checkpoint_ref) do
      nil -> false
      # A repository that no longer exists was not pruned by BM.
      ref -> File.dir?(root) and Git.rev_parse(root, ref) == nil
    end
  end

  defp pruned?(_run, _root, _attempts), do: false

  ## Notifications (plan 16.2)

  # The page asks the browser to notify (and marks the tab title) when a run needs the user.
  defp notify_if_ended(socket, %{status: :active}, %{status: status} = run)
       when status in [:done, :failed, :cancelled, :paused] do
    verb = if status == :paused, do: "paused", else: to_string(status)

    push_event(socket, "bm:notify", %{
      title: "#{label(run)} #{verb}",
      body: run.status_reason || String.slice(run.goal, 0, 120)
    })
  end

  defp notify_if_ended(socket, _before, _after), do: socket

  defp notify_if_held(socket, {:held, _} = lane, attempt) do
    if socket.assigns.lane != lane do
      push_event(socket, "bm:notify", %{
        title: "#{label(socket.assigns.run)} needs your decision",
        body: attempt.error || "An attempt left changes BM could not accept: Keep or Revert."
      })
    else
      socket
    end
  end

  defp notify_if_held(socket, _lane, _attempt), do: socket

  ## Live activity (canvas and action bar)

  # Watches the planner's pi session and the running worker's, if any.
  defp watch_live(socket, attempt) do
    run = socket.assigns.run

    socket =
      case run.planner do
        %{"agent_id" => agent_id} when run.status == :active -> watch(socket, agent_id)
        _ -> socket
      end

    watch_worker(socket, attempt)
  end

  defp watch_worker(socket, %{status: status, id: id} = attempt)
       when status in [:admitted, :running, :result_received, :settling] do
    agent_id = "attempt-#{id}"
    task = attempt.task || Runs.get_task!(attempt.task_id)
    socket |> watch(agent_id) |> assign(worker: {agent_id, task.key})
  end

  defp watch_worker(socket, _attempt) do
    case socket.assigns.worker do
      {agent_id, key} ->
        Bm.Pi.unsubscribe(agent_id)

        socket
        |> assign(
          worker: nil,
          worker_tool: nil,
          watching: MapSet.delete(socket.assigns.watching, agent_id),
          live: Map.delete(socket.assigns.live, RunGraph.task_node(key))
        )

      nil ->
        socket
    end
  end

  # The worker's activity: the tool running now (nil between tools), the last one, and how many
  # tool calls it made. Tools often run for milliseconds, so the last one is what users see.
  defp next_activity(nil, tool), do: next_activity(%{now: nil, last: nil, calls: 0}, tool)

  defp next_activity(activity, nil), do: %{activity | now: nil}
  defp next_activity(%{now: tool} = activity, tool), do: activity

  defp next_activity(activity, tool),
    do: %{activity | now: tool, last: tool, calls: activity.calls + 1}

  defp watch(socket, agent_id) do
    if MapSet.member?(socket.assigns.watching, agent_id) do
      socket
    else
      Bm.Pi.subscribe(agent_id)
      assign(socket, watching: MapSet.put(socket.assigns.watching, agent_id))
    end
  end

  # Redraws the canvas of a goal run from the database plus the live activity.
  defp refresh_graph(%{assigns: %{goal_run?: true}} = socket) do
    run = socket.assigns.run

    push_event(
      socket,
      "flow:set_graph",
      RunGraph.build(run, Runs.latest_tasks(run), socket.assigns.live)
    )
  end

  defp refresh_graph(socket), do: socket

  # Merges live data into one canvas node, pushing only what changed.
  defp update_live(socket, node, data) do
    if Map.get(socket.assigns.live, node) == data do
      socket
    else
      socket = assign(socket, live: Map.put(socket.assigns.live, node, data))

      if socket.assigns.goal_run?,
        do: push_event(socket, "flow:update_node", %{id: node, data: data}),
        else: socket
    end
  end

  defp planner_phase(%{planner: nil}), do: nil

  defp planner_phase(run) do
    case Planner.state(run.id) do
      %{phase: phase} -> phase
      nil -> nil
    end
  catch
    :exit, _ -> nil
  end

  # The lane matters only for the workspace's unfinished run; the coordinator knows it.
  defp lane(%{status: status, workspace: workspace}) when status in [:active, :paused] do
    with {:ok, _pid} <- Coordinator.ensure_started(workspace.path),
         %{lane: lane} <- Coordinator.state(workspace.path) do
      lane
    else
      _ -> :unknown
    end
  end

  defp lane(_run), do: :finished

  # Stream items: the attempt, its task, and the diff of each changed file once it settled.
  defp decorate(attempt, root) do
    %{id: attempt.id, attempt: attempt, task: attempt.task, diffs: diffs(attempt, root)}
  end

  defp diffs(%{tree_before: before, tree_after: after_tree, actual_writes: writes}, root)
       when is_binary(before) and is_binary(after_tree) do
    for %{"path" => path, "status" => status} <- writes do
      text =
        case Git.file_diff(root, before, after_tree, path) do
          {:ok, text} -> text
          {:error, _} -> ""
        end

      %{path: path, status: status, text: text}
    end
  end

  defp diffs(_attempt, _root), do: []

  ## Updates from the coordinator

  @impl true
  def handle_info({:workspace, _root, {:attempt, attempt, lane}}, socket) do
    %{task: task} = Runs.attempt_context(attempt)

    if task.run_id == socket.assigns.run.id do
      attempt = %{attempt | task: task}

      socket = notify_if_held(socket, lane, attempt)

      {:noreply,
       socket
       |> assign(lane: lane, latest: attempt, run: reload(socket.assigns.run))
       |> watch_worker(attempt)
       |> stream_insert(:tasks, task)
       |> stream_insert(:attempts, decorate(attempt, socket.assigns.root))
       |> refresh_graph()}
    else
      {:noreply, socket}
    end
  end

  # pi activity of the planner or of the running worker.
  def handle_info({:pi, agent_id, _event, summary}, socket) do
    socket =
      case socket.assigns do
        %{worker: {^agent_id, key}} ->
          activity = next_activity(socket.assigns.worker_tool, summary[:tool])

          socket
          |> assign(worker_tool: activity)
          |> update_live(RunGraph.task_node(key), RunGraph.task_live(summary, activity))

        %{run: %{planner: %{"agent_id" => ^agent_id}}} ->
          update_live(socket, RunGraph.planner_node(), RunGraph.planner_live(summary))

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:workspace, _root, {:task, %{run_id: id} = task}},
        %{assigns: %{run: %{id: id}}} = socket
      ),
      do: {:noreply, socket |> stream_insert(:tasks, task) |> refresh_graph()}

  def handle_info(
        {:workspace, _root, {:planner, id, info}},
        %{assigns: %{run: %{id: id}}} = socket
      ),
      do: {:noreply, assign(socket, planner_phase: info.phase)}

  def handle_info(
        {:workspace, _root, {:run, %{id: id} = run}},
        %{assigns: %{run: %{id: id}}} = socket
      ) do
    run = %{run | workspace: socket.assigns.run.workspace}
    lane = if run.status in [:active, :paused], do: socket.assigns.lane, else: :finished
    socket = notify_if_ended(socket, socket.assigns.run, run)

    socket =
      if run.planner != nil and run.status != :active,
        # Ending or pausing may cancel queued tasks without a task event.
        do:
          socket
          |> stream(:tasks, Runs.list_tasks(run), reset: true)
          |> assign(planner_phase: nil),
        else: socket

    socket = assign(socket, run: run, lane: lane)

    # A resumed run has a new planner session to watch.
    socket =
      case run.planner do
        %{"agent_id" => agent_id} when run.status == :active -> watch(socket, agent_id)
        _ -> socket
      end

    {:noreply, refresh_graph(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(run), do: %{Runs.get_run!(run.id) | workspace: run.workspace}

  ## Actions

  @impl true
  def handle_event("stop", _params, socket), do: act(socket, &Coordinator.cancel/1)
  def handle_event("keep", _params, socket), do: act(socket, &Coordinator.keep/1)

  def handle_event("revert", _params, socket) do
    case Coordinator.revert(socket.assigns.root) do
      :ok ->
        {:noreply, socket}

      {:error, {:changed_since, paths}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not reverted: #{Enum.join(paths, ", ")} changed since the attempt. Nothing was touched."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not reverted: #{explain_action(reason)}")}
    end
  end

  def handle_event("finish", _params, socket) do
    case Coordinator.finish_run(socket.assigns.root) do
      {:ok, run} ->
        {:noreply,
         assign(socket, run: %{run | workspace: socket.assigns.run.workspace}, lane: :finished)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not finish the run: #{explain_action(reason)}")}
    end
  end

  # The canvas reports drags; positions are not stored.
  def handle_event("flow_changed", _graph, socket), do: {:noreply, socket}

  def handle_event("commit_run", _params, socket) do
    case Coordinator.commit_run(socket.assigns.root, socket.assigns.run.id) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(run: %{run | workspace: socket.assigns.run.workspace})
         |> put_flash(:info, "Committed as #{String.slice(run.commit_sha, 0, 8)} on your branch.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not committed: #{explain_commit(reason)}")}
    end
  end

  def handle_event("revert_task", %{"task" => task_id}, socket) do
    case Coordinator.revert_task(socket.assigns.root, String.to_integer(task_id)) do
      {:ok, task} ->
        {:noreply,
         put_flash(socket, :info, "Undone: the files of task #{task.key} are back as before it.")}

      {:error, {:changed_since, paths}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not undone: #{Enum.join(paths, ", ")} changed since the task. Nothing was touched."
         )}

      {:error, {:dependents, keys}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not undone: #{Enum.join(keys, ", ")} #{if length(keys) == 1, do: "depends", else: "depend"} " <>
             "on this task. Undo #{if length(keys) == 1, do: "it", else: "them"} first."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not undone: #{explain_action(reason)}")}
    end
  end

  def handle_event("revert_run", _params, socket) do
    case Coordinator.revert_run(socket.assigns.root, socket.assigns.run.id) do
      {:ok, run} ->
        attempts = Runs.list_run_attempts_with_tasks(run)

        {:noreply,
         socket
         |> assign(run: %{run | workspace: socket.assigns.run.workspace})
         |> stream(:attempts, Enum.map(attempts, &decorate(&1, socket.assigns.root)), reset: true)
         |> put_flash(:info, "Reverted: every change this run left is back as it was before.")}

      {:error, {:changed_since, paths}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not reverted: #{Enum.join(paths, ", ")} changed since the run. Nothing was touched."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not reverted: #{explain_action(reason)}")}
    end
  end

  def handle_event("resume_planning", _params, socket) do
    case Coordinator.resume_planning(socket.assigns.root, socket.assigns.run.id) do
      {:ok, run} ->
        {:noreply, assign(socket, run: %{run | workspace: socket.assigns.run.workspace})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not resume: #{explain_action(reason)}")}
    end
  end

  def handle_event("next", %{"next" => %{"goal" => goal}}, socket) do
    goal = String.trim(goal)

    attrs = %{title: BmWeb.HomeLive.title(goal), goal: goal}

    with false <- goal == "",
         {:ok, _attempt} <- Coordinator.run_task(socket.assigns.root, attrs) do
      {:noreply, assign(socket, form: to_form(%{"goal" => ""}, as: :next))}
    else
      true ->
        {:noreply, socket}

      {:error, reason} ->
        {_field, message} = BmWeb.HomeLive.explain(reason, socket.assigns.root)
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @doc false
  # Why an action on the run was refused, in words.
  def explain_action(:nothing_running), do: "no attempt is running."
  def explain_action(:nothing_held), do: "no attempt is waiting for a decision."
  def explain_action(:attempt_running), do: "an attempt is running; stop it or wait for it."

  def explain_action(:lane_busy),
    do: "an attempt is running or waiting for your decision; resolve it first."

  def explain_action(:no_run), do: "this workspace has no unfinished run."
  def explain_action(:nothing_to_revert), do: "the latest attempt changed nothing to revert."

  def explain_action({:not_revertable, status}),
    do: "the latest attempt is #{status |> to_string() |> String.replace("_", " ")}."

  def explain_action(:not_resumable), do: "only a paused goal run can resume planning."
  def explain_action(:already_reverted), do: "this run was already reverted."
  def explain_action(:run_not_finished), do: "finish the run first."

  def explain_action(:workspace_busy),
    do: "the workspace has an unfinished run; finish it first."

  def explain_action(:run_not_active), do: "this run is no longer the workspace's active run."

  def explain_action(:not_started),
    do: "BM is not managing this workspace right now; reload the page."

  def explain_action(other), do: "unexpected error (#{inspect(other)})."

  @doc false
  def explain_commit({:changed_since, paths}),
    do: "#{Enum.join(paths, ", ")} changed since the run; commit them yourself if you want them."

  def explain_commit({:staged, paths}),
    do: "you have staged changes in #{Enum.join(paths, ", ")}; unstage or commit them first."

  def explain_commit(:detached_head), do: "HEAD is not on a branch; check out a branch first."
  def explain_commit(:no_commits), do: "the repository has no commit yet."
  def explain_commit(:nothing_to_commit), do: "the run's changes are already in HEAD."

  def explain_commit({:already_committed, sha}),
    do: "this run was already committed (#{String.slice(sha, 0, 8)})."

  def explain_commit({:git, _cmd, _status, output}),
    do: "git refused: #{output |> String.trim() |> String.slice(0, 200)}"

  def explain_commit(other), do: explain_action(other)

  defp act(socket, fun) do
    case fun.(socket.assigns.root) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not possible now: #{explain_action(reason)}")}
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:tasks}>
      <div class="mx-auto max-w-4xl px-4 py-6">
        <header class="flex flex-wrap items-start gap-x-4 gap-y-2">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-bm-muted">
              <.run_status id="run-status" status={@run.status} />
              <div class="bm-meta flex flex-wrap items-center gap-y-1">
                <span id="run-label" class="font-mono">{label(@run)}</span>
                <span>started <.ago at={@run.inserted_at} /></span>
                <span :if={@run.finished_at}>
                  took {duration(@run.inserted_at, @run.finished_at)}
                </span>
              </div>
            </div>
            <h1 id="run-goal" class="mt-1.5 text-lg font-semibold leading-snug">{@run.goal}</h1>
            <p class="mt-1 flex min-w-0 items-baseline gap-1.5 text-[11px]" title={@root}>
              <span class="flex-none font-mono font-medium">{Path.basename(@root)}</span>
              <span class="min-w-0 truncate font-mono text-bm-muted">{@root}</span>
            </p>
            <p
              :if={@run.status_reason}
              id="run-reason"
              class={[
                "mt-2 text-xs",
                if(@run.status in [:failed, :paused], do: "text-bm-run", else: "text-bm-muted")
              ]}
            >
              {String.capitalize(@run.status_reason)}.
            </p>
          </div>
          <div
            id="run-notify"
            phx-hook=".Notify"
            phx-update="ignore"
            class="flex flex-none items-center"
          >
            <button
              type="button"
              data-role="enable"
              hidden
              class="rounded-md border border-bm-line px-2 py-1 text-[11px] text-bm-muted transition-colors hover:bg-bm-raised hover:text-bm-text"
            >
              Notify me
            </button>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".Notify">
            export default {
              mounted() {
                const button = this.el.querySelector("[data-role=enable]")
                const supported = "Notification" in window
                const show = () => { button.hidden = !supported || Notification.permission !== "default" }
                show()
                button.addEventListener("click", () => Notification.requestPermission().then(show))
                this.baseTitle = document.title
                const clear = () => { if (document.title.startsWith("● ")) document.title = document.title.slice(2) }
                window.addEventListener("focus", clear)
                document.addEventListener("visibilitychange", () => { if (!document.hidden) clear() })
                this.handleEvent("bm:notify", ({title, body}) => {
                  if (document.hasFocus()) return
                  if (!document.title.startsWith("● ")) document.title = "● " + document.title
                  if (supported && Notification.permission === "granted") new Notification(title, {body})
                })
              }
            }
          </script>
          <dl id="run-spend" class="text-right">
            <dt class="text-[11px] text-bm-muted">Spent</dt>
            <dd class="font-mono text-sm tabular-nums">
              {money(@run.spent_usd)}<span :if={@run.budget_usd} class="text-bm-muted"> / {money(
                @run.budget_usd
              )}</span>
            </dd>
            <dd
              :if={@goal_run? and is_number(@run.planner["spend"])}
              id="spend-split"
              class="text-[11px] text-bm-muted"
            >
              planner {money(@run.planner["spend"])} · work and review {money(
                max(@run.spent_usd - @run.planner["spend"], 0.0)
              )}
            </dd>
            <dd :if={@run.spent_unknown > 0} class="text-[11px] text-bm-run">
              + {@run.spent_unknown} without a cost
            </dd>
            <dd
              :if={budget_low?(@run)}
              id="budget-warning"
              class="text-[11px] font-medium text-bm-run"
            >
              {round(@run.spent_usd / @run.budget_usd * 100)} % of the budget used
            </dd>
          </dl>
        </header>

        <.baseline_warning run={@run} />

        <.action_bar
          lane={@lane}
          latest={@latest}
          run={@run}
          root={@root}
          form={@form}
          checkpoints_pruned?={@checkpoints_pruned?}
          goal_run?={@goal_run?}
          planner_phase={@planner_phase}
          worker_tool={@worker_tool}
        />

        <section
          :if={@goal_run?}
          id="run-canvas"
          phx-hook="FlowCanvas"
          phx-update="ignore"
          data-graph={JSON.encode!(@graph)}
          class="mt-6 hidden h-80 overflow-hidden rounded-xl border border-bm-line md:block"
          aria-label="Run graph: planner, tasks and dependencies"
        >
        </section>

        <section
          :if={@goal_run?}
          id="plan"
          class="mt-6 grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
        >
          <.planner_panel run={@run} phase={@planner_phase} />
          <div class="min-w-0">
            <h2 class="text-xs font-semibold">Tasks</h2>
            <ol id="tasks" phx-update="stream" class="mt-2 space-y-1.5">
              <li
                id="tasks-empty"
                class="hidden rounded-lg border border-dashed border-bm-line p-4 text-center text-xs text-bm-muted only:block"
              >
                The planner has not proposed any task yet.
              </li>
              <li :for={{dom_id, task} <- @streams.tasks} id={dom_id}>
                <.task_row task={task} />
              </li>
            </ol>
          </div>
        </section>

        <h2 :if={@goal_run?} class="mt-8 text-xs font-semibold">Attempts</h2>
        <ol id="attempts" phx-update="stream" class="mt-6 space-y-4">
          <li
            id="attempts-empty"
            class="hidden rounded-xl border border-dashed border-bm-line p-6 text-center text-xs text-bm-muted only:block"
          >
            No attempts yet.
          </li>
          <li :for={{dom_id, item} <- @streams.attempts} id={dom_id}>
            <.attempt_card
              item={item}
              undo?={
                @run.status in [:done, :failed, :cancelled] and @run.reverted_at == nil and
                  @run.commit_sha == nil
              }
            />
          </li>
        </ol>
      </div>
    </Layouts.app>
    """
  end

  attr :run, :any, required: true

  # Shown when the verify command already failed on the checkout as the user left it: a failing
  # verification afterwards is then not the worker's doing.
  defp baseline_warning(%{run: %{baseline_verify: %{"exit" => exit} = verify}} = assigns)
       when exit != 0 do
    assigns = assign(assigns, verify: verify)

    ~H"""
    <details
      id="baseline-warning"
      class="group mt-5 rounded-xl border border-bm-run/50 bg-bm-run/10 px-4 py-2.5"
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 text-xs">
        <span class="text-bm-muted transition-transform group-open:rotate-90">›</span>
        <span class="font-semibold text-bm-run">Your checkout already fails verification</span>
        <span class="font-mono text-[11px] text-bm-muted">{verify_label(@verify)} before any attempt</span>
      </summary>
      <p class="mt-2 text-xs text-bm-muted">
        The verify command was run once before the first attempt and did not pass. Attempts still
        run, but a failing verification may not be the worker's doing. Fix the checkout or the
        verify command, then start a new run.
      </p>
      <pre
        :if={@verify["output"] not in [nil, ""]}
        class="mt-2 max-h-72 overflow-auto rounded-md bg-bm-bg px-3 py-2 font-mono text-[11px] leading-relaxed"
      >{@verify["output"]}</pre>
    </details>
    """
  end

  defp baseline_warning(
         %{run: %{baseline_verify: %{"changed" => [_ | _] = changed}} = run} = assigns
       ) do
    owned = get_in(run.baseline, ["user_owned"]) || []

    case Enum.filter(changed, &(&1 in owned)) do
      [] ->
        ~H""

      touched ->
        assigns = assign(assigns, touched: touched)

        ~H"""
        <p
          id="baseline-warning"
          class="mt-5 rounded-xl border border-bm-run/50 bg-bm-run/10 px-4 py-2.5 text-xs"
        >
          <span class="font-semibold text-bm-run">Your verify command changed your uncommitted files</span>
          before any attempt ran: <span class="font-mono">{Enum.join(@touched, ", ")}</span>.
          BM did not touch them itself; check the command if that was not intended.
        </p>
        """
    end
  end

  defp baseline_warning(assigns), do: ~H""

  attr :run, :map, required: true
  attr :phase, :atom, default: nil

  # The goal run's planner: what it is doing, its waves, its summary and its log.
  defp planner_panel(assigns) do
    planner = assigns.run.planner || %{}
    assigns = assign(assigns, planner: planner, log: Enum.reverse(planner["log"] || []))

    ~H"""
    <div id="planner" class="min-w-0 rounded-xl border border-bm-line bg-bm-surface">
      <header class="flex flex-wrap items-center gap-2 border-b border-bm-line px-3 py-2">
        <span class={[
          "size-1.5 rounded-full",
          if(@phase in [:starting, :busy],
            do: "animate-pulse bg-bm-run motion-reduce:animate-none",
            else: "bg-bm-muted"
          )
        ]}></span>
        <h2 class="text-xs font-semibold">Planner</h2>
        <span id="planner-phase" class="text-[11px] text-bm-muted">{phase_label(@phase, @run)}</span>
        <span class="ml-auto font-mono text-[10px] text-bm-muted">
          wave {@planner["waves"] || 1} · plan {if @run.plan_open, do: "open", else: "closed"}
        </span>
      </header>
      <p
        :if={@planner["summary"]}
        id="planner-summary"
        class="border-b border-bm-line px-3 py-2 text-xs"
      >
        <span class="text-bm-muted">Plan:</span> {@planner["summary"]}
      </p>
      <ol class="max-h-96 space-y-2 overflow-y-auto px-3 py-2">
        <li :if={@log == []} class="text-xs text-bm-muted">Nothing yet.</li>
        <li :for={entry <- @log} class="text-xs">
          <details class="group" open={entry["kind"] in ["reply", "end", "paused", "answer"]}>
            <summary class="flex cursor-pointer list-none items-center gap-2">
              <span class="text-bm-muted transition-transform group-open:rotate-90">›</span>
              <span class={["flex-none whitespace-nowrap font-medium", log_tone(entry["kind"])]}>
                {log_label(entry["kind"])}
              </span>
              <span class="truncate text-[11px] text-bm-muted">{first_line(entry["text"])}</span>
            </summary>
            <div
              :if={entry["kind"] == "reply"}
              class="bm-prose mt-1 max-h-72 overflow-y-auto rounded-md bg-bm-bg px-2.5 py-1.5"
            >
              {markdown(entry["text"])}
            </div>
            <pre
              :if={entry["kind"] != "reply"}
              class="mt-1 max-h-60 overflow-y-auto whitespace-pre-wrap rounded-md bg-bm-bg px-2.5 py-1.5 font-sans text-xs leading-relaxed"
              phx-no-format
            >{String.trim(entry["text"])}</pre>
          </details>
        </li>
      </ol>
    </div>
    """
  end

  defp phase_label(:starting, _run), do: "starting"
  defp phase_label(:busy, _run), do: "thinking"
  defp phase_label(:idle, _run), do: "waiting while tasks run"
  defp phase_label(:answering, _run), do: "answering a worker"
  defp phase_label(_phase, %{status: :active}), do: "not running"
  defp phase_label(_phase, _run), do: "finished"

  defp log_label("prompt"), do: "Goal sent"
  defp log_label("results"), do: "Results sent"
  defp log_label("reminder"), do: "Reminder sent"
  defp log_label("reply"), do: "Planner"
  defp log_label("end"), do: "Run ended"
  defp log_label("paused"), do: "Run paused"
  defp log_label("note"), do: "Note"
  defp log_label("question"), do: "Worker asked"
  defp log_label("answer"), do: "Planner answered"
  defp log_label(kind), do: kind

  defp log_tone(kind) when kind in ["paused"], do: "text-bm-run"
  defp log_tone("reply"), do: "text-bm-text"
  defp log_tone(_kind), do: "text-bm-muted"

  # The planner's replies are markdown; MDEx drops raw HTML (render: [unsafe: false]).
  defp markdown(text) do
    text
    |> MDEx.to_html!(
      extension: [table: true, strikethrough: true, autolink: true],
      render: [unsafe: false]
    )
    |> Phoenix.HTML.raw()
  end

  defp first_line(text), do: text |> String.split("\n", trim: true) |> List.first("")

  attr :task, :map, required: true

  defp task_row(assigns) do
    ~H"""
    <div class="rounded-lg border border-bm-line bg-bm-surface px-3 py-2">
      <div class="flex items-center gap-2">
        <.task_status id={"task-#{@task.id}-status"} status={@task.status} />
        <span class="min-w-0 flex-1 truncate text-[13px] font-medium" title={@task.title}>{@task.title}</span>
        <span :if={@task.revision > 1} class="rounded bg-bm-raised px-1 text-[10px] text-bm-muted">re-planned</span>
      </div>
      <div class="bm-meta mt-1 flex flex-wrap items-center gap-y-0.5 font-mono text-[10px] text-bm-muted">
        <span>{@task.key}</span>
        <span :if={@task.depends_on != []}>after {Enum.join(@task.depends_on, ", ")}</span>
        <span :if={!@task.mutates}>read-only</span>
        <span :if={@task.writes != []} class="min-w-0 truncate">{Enum.join(@task.writes, ", ")}</span>
        <span :if={@task.check}>check: {@task.check}</span>
      </div>
    </div>
    """
  end

  attr :lane, :any, required: true
  attr :latest, :any, required: true
  attr :run, :any, required: true
  attr :root, :string, required: true
  attr :form, :any, required: true
  attr :goal_run?, :boolean, default: false
  attr :planner_phase, :atom, default: nil
  attr :worker_tool, :map, default: nil
  attr :checkpoints_pruned?, :boolean, default: false

  defp action_bar(assigns) do
    ~H"""
    <div
      id="actions"
      class="sticky top-11 z-10 -mx-4 mt-5 border-y border-bm-line bg-bm-bg/95 px-4 py-2.5 backdrop-blur sm:mx-0 sm:rounded-xl sm:border"
    >
      <%= case @lane do %>
        <% {:busy, _id} -> %>
          <div class="flex items-center gap-3">
            <span class="size-1.5 animate-pulse rounded-full bg-bm-run motion-reduce:animate-none"></span>
            <p class="min-w-0 flex-1 text-xs">
              An attempt is running. Its changes are checked when it finishes.
              <span
                :if={@worker_tool}
                id="worker-tool"
                class="mt-0.5 block truncate font-mono text-[11px] text-bm-run"
                title={@worker_tool.now || @worker_tool.last}
              >
                {activity_text(@worker_tool)}
              </span>
            </p>
            <.action id="stop-btn" event="stop" style={:secondary} disable_with="Stopping…">
              Stop
            </.action>
          </div>
        <% {:held, _id} -> %>
          <div class="flex flex-wrap items-center gap-3">
            <p class="min-w-0 flex-1 text-xs">
              <span class="font-semibold text-bm-run">Your decision:</span>
              {held_reason(@latest)} Keep the files as they are, or revert them to how they were
              before the attempt.
            </p>
            <.action id="revert-btn" event="revert" style={:secondary} disable_with="Reverting…">
              Revert
            </.action>
            <.action id="keep-btn" event="keep" style={:primary} disable_with="Keeping…">
              Keep
            </.action>
          </div>
        <% :finished -> %>
          <div class="flex flex-wrap items-center gap-3">
            <p class="min-w-0 flex-1 text-xs text-bm-muted">
              <%= if @run.commit_sha do %>
                This run is finished and its changes were committed as
                <code class="font-mono">{String.slice(@run.commit_sha, 0, 8)}</code>
                on your branch.
              <% else %>
                <%= if @run.reverted_at do %>
                  This run is finished and was reverted <.ago at={@run.reverted_at} />: every file
                  it changed is back as it was before the run. Its checkpoints stay as the record.
                <% else %>
                  <%= if @checkpoints_pruned? do %>
                    This run is finished. Its checkpoints were pruned after newer runs; accepted
                    changes stay in your working tree, and old diffs may be gone.
                  <% else %>
                    This run is finished. Accepted changes are in your working tree and checkpointed
                    under <code class="font-mono">refs/bm/runs/{@run.id}/</code>.
                  <% end %>
                <% end %>
              <% end %>
            </p>
            <.action
              :if={@run.reverted_at == nil and @run.commit_sha == nil and run_revertable?(@run)}
              id="commit-run-btn"
              event="commit_run"
              style={:secondary}
              disable_with="Committing…"
              confirm="Commit this run's changes on your current branch? Only the run's files are committed; your other changes stay as they are."
            >
              Commit these changes
            </.action>
            <.action
              :if={@run.reverted_at == nil and @run.commit_sha == nil and run_revertable?(@run)}
              id="revert-run-btn"
              event="revert_run"
              style={:secondary}
              disable_with="Reverting…"
              confirm="Put back every file this run changed, as it was before the run?"
            >
              Revert this run
            </.action>
            <.link
              id="new-task-link"
              navigate={~p"/?#{%{path: @root, mode: if(@goal_run?, do: "goal", else: "task")}}"}
              class="rounded-md bg-bm-text px-3 py-1.5 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85"
            >
              {if @goal_run?, do: "New goal here", else: "New task here"}
            </.link>
          </div>
        <% _free when @goal_run? and @run.status == :paused -> %>
          <div class="flex flex-wrap items-center gap-3">
            <p class="min-w-0 flex-1 text-xs">
              <span class="font-semibold text-bm-run">Paused.</span>
              Resume planning starts a new planner session that knows the tasks so far; Finish
              ends the run and keeps what was accepted.
            </p>
            <.action id="finish-run-btn" event="finish" style={:secondary} disable_with="Finishing…">
              Finish run
            </.action>
            <.action
              id="resume-planning-btn"
              event="resume_planning"
              style={:primary}
              disable_with="Resuming…"
            >
              Resume planning
            </.action>
          </div>
        <% _free when @goal_run? -> %>
          <div class="flex flex-wrap items-center gap-3">
            <span
              :if={@planner_phase in [:starting, :busy]}
              class="size-1.5 animate-pulse rounded-full bg-bm-run motion-reduce:animate-none"
            ></span>
            <p class="min-w-0 flex-1 text-xs">
              {if @planner_phase in [:starting, :busy],
                do: "The planner is working. Tasks start when it has proposed them.",
                else: "The planner chooses the next task; nothing waits for you."}
            </p>
            <.action
              :if={revertable?(@latest)}
              id="revert-btn"
              event="revert"
              style={:secondary}
              disable_with="Reverting…"
            >
              Revert last change
            </.action>
            <.action id="finish-run-btn" event="finish" style={:secondary} disable_with="Finishing…">
              Finish run
            </.action>
          </div>
        <% _free -> %>
          <.form
            for={@form}
            id="next-task-form"
            phx-submit="next"
            class="flex flex-wrap items-center gap-2"
          >
            <div class="min-w-0 flex-1 [&_.fieldset]:mb-0">
              <.input
                field={@form[:goal]}
                id="next-task-input"
                aria-label="Next task"
                placeholder={
                  if @run.status == :paused, do: "Run paused", else: "Next task in this run…"
                }
                disabled={@run.status != :active}
                class="w-full rounded-md border border-bm-line bg-bm-surface px-2.5 py-1.5 text-[13px] outline-none transition-colors placeholder:text-bm-muted/70 focus:border-bm-muted"
              />
            </div>
            <button
              id="next-task-btn"
              type="submit"
              phx-disable-with="Starting…"
              disabled={@run.status != :active}
              class="rounded-md bg-bm-text px-3 py-1.5 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85 disabled:opacity-50"
            >
              Run
            </button>
            <.action
              :if={revertable?(@latest)}
              id="revert-btn"
              event="revert"
              style={:secondary}
              disable_with="Reverting…"
            >
              Revert last change
            </.action>
            <.action id="finish-run-btn" event="finish" style={:secondary} disable_with="Finishing…">
              Finish run
            </.action>
          </.form>
      <% end %>
    </div>
    """
  end

  # Soft budget warning (plan 11.5): an unfinished run past 80 % of its budget.
  defp budget_low?(%{status: status, budget_usd: budget, spent_usd: spent})
       when status in [:active, :paused] and is_number(budget) and budget > 0,
       do: spent >= 0.8 * budget

  defp budget_low?(_run), do: false

  defp activity_text(%{now: now, calls: calls}) when is_binary(now),
    do: "Now: #{now} · #{calls} tool #{if calls == 1, do: "call", else: "calls"}"

  defp activity_text(%{last: last, calls: calls}) when is_binary(last),
    do: "Thinking · last: #{last} · #{calls} tool #{if calls == 1, do: "call", else: "calls"}"

  defp activity_text(_activity), do: "Thinking…"

  # A finished run with at least one checkpoint left something to revert.
  defp run_revertable?(run), do: Enum.any?(Runs.list_run_attempts(run), & &1.checkpoint_ref)

  defp revertable?(%{status: :accepted, actual_writes: [_ | _]}), do: true
  defp revertable?(_attempt), do: false

  defp held_reason(%{status: :needs_reconciliation}),
    do: "BM was interrupted while an attempt was changing files, so its result is unknown."

  defp held_reason(%{verify: %{"timeout" => true}}),
    do: "the last attempt's changes could not be verified: the verify command timed out."

  defp held_reason(%{verify: %{"exit" => code}}) when is_integer(code) and code != 0,
    do: "the last attempt's changes failed verification."

  defp held_reason(%{error: error}) when is_binary(error), do: "the last attempt #{error}."
  defp held_reason(_attempt), do: "the last attempt left changes BM could not accept."

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :style, :atom, default: :secondary
  attr :disable_with, :string, default: nil
  attr :confirm, :string, default: nil
  slot :inner_block, required: true

  defp action(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-disable-with={@disable_with}
      data-confirm={@confirm}
      class={[
        "rounded-md px-3 py-1.5 text-xs font-semibold transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bm-text disabled:opacity-60",
        if(@style == :primary,
          do: "bg-bm-text text-bm-surface hover:opacity-85",
          else: "border border-bm-line bg-bm-surface hover:bg-bm-raised"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :item, :map, required: true
  attr :undo?, :boolean, default: false

  defp attempt_card(%{item: %{attempt: attempt, task: task}} = assigns) do
    assigns = assign(assigns, attempt: attempt, task: task, result: attempt.result || %{})

    ~H"""
    <article class="overflow-hidden rounded-xl border border-bm-line bg-bm-surface">
      <header class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-bm-line px-4 py-2.5">
        <.attempt_status id={"attempt-#{@attempt.id}-status"} status={@attempt.status} />
        <h2 class="min-w-0 flex-1 truncate text-[13px] font-semibold" title={@task.title}>
          {@task.title}
        </h2>
        <span class="basis-full font-mono text-[10px] text-bm-muted sm:basis-auto">
          {@task.key} · attempt {@attempt.number} · {@attempt.role}
        </span>
      </header>

      <div class="space-y-3 px-4 py-3">
        <div class="bm-meta flex flex-wrap items-center gap-y-1 text-[11px] text-bm-muted">
          <span>started <.ago at={@attempt.inserted_at} /></span>
          <span :if={terminal?(@attempt.status)}>
            took {duration(@attempt.inserted_at, @attempt.updated_at)}
          </span>
          <span :if={@attempt.checkpoint_ref}>
            checkpoint
            <code class="rounded bg-bm-raised px-1 font-mono">{@attempt.checkpoint_ref}</code>
          </span>
        </div>

        <details :if={@task.goal != @task.title} id={"task-#{@attempt.id}"} class="group">
          <summary class="flex cursor-pointer list-none items-center gap-2 text-xs">
            <span class="text-bm-muted transition-transform group-open:rotate-90">›</span>
            <span class="font-medium">Task</span>
            <span :if={@task.writes != []} class="font-mono text-[11px] text-bm-muted">
              {Enum.join(@task.writes, ", ")}
            </span>
          </summary>
          <p class="mt-2 whitespace-pre-wrap rounded-md bg-bm-bg px-3 py-2 text-xs leading-relaxed">
            {@task.goal}
          </p>
        </details>

        <p :if={@result["summary"]} class="text-[13px] leading-relaxed">
          <span class="text-bm-muted">Worker:</span> {@result["summary"]}
        </p>

        <details :if={@attempt.transcript != []} id={"activity-#{@attempt.id}"} class="group">
          <summary class="flex cursor-pointer list-none items-center gap-2 text-xs">
            <span class="text-bm-muted transition-transform group-open:rotate-90">›</span>
            <span class="font-medium">Activity</span>
            <span class="text-[11px] text-bm-muted">{activity_summary(@attempt.transcript)}</span>
          </summary>
          <ol class="mt-2 max-h-96 space-y-1 overflow-y-auto rounded-md bg-bm-bg px-3 py-2">
            <li :for={entry <- @attempt.transcript} class="text-xs">
              <%= case entry["t"] do %>
                <% "tool" -> %>
                  <div class="flex min-w-0 items-baseline gap-2 font-mono text-[11px]">
                    <span class={["flex-none", tool_tone(entry["status"])]}>
                      {tool_mark(entry["status"])}
                    </span>
                    <span class="flex-none font-semibold">{entry["name"]}</span>
                    <span class="min-w-0 truncate text-bm-muted" title={entry["detail"]}>
                      {entry["detail"]}
                    </span>
                  </div>
                <% "text" -> %>
                  <div class="bm-prose border-l-2 border-bm-line py-0.5 pl-2">
                    {markdown(entry["text"])}
                  </div>
                <% _other -> %>
                  <p class="text-[11px] text-bm-run">{entry["text"]}</p>
              <% end %>
            </li>
          </ol>
        </details>

        <p
          :if={@attempt.error}
          id={"attempt-#{@attempt.id}-error"}
          class="rounded-md border-l-2 border-bm-error bg-bm-error/10 px-2.5 py-1.5 text-xs"
        >
          {@attempt.error}
        </p>

        <ul :if={@attempt.flags != []} class="flex flex-wrap gap-1.5">
          <li
            :for={flag <- @attempt.flags}
            class="rounded-full bg-bm-raised px-2 py-0.5 font-mono text-[10px] text-bm-muted"
            title={flag_help(flag)}
          >
            {flag}
          </li>
        </ul>

        <details
          :if={@attempt.verify}
          id={"verify-#{@attempt.id}"}
          open={verify_needs_reading?(@attempt)}
          class="group"
        >
          <summary class="flex cursor-pointer list-none items-center gap-2 text-xs">
            <span class="text-bm-muted transition-transform group-open:rotate-90">›</span>
            <span class="font-medium">Verification</span>
            <span class={["font-mono text-[11px]", verify_tone(@attempt.verify)]}>
              {verify_label(@attempt.verify)}
            </span>
            <span
              :if={is_map(@attempt.verify["review"])}
              class={["font-mono text-[11px]", review_tone(@attempt.verify["review"])]}
            >
              · {review_label(@attempt.verify["review"])}
            </span>
          </summary>
          <pre
            :if={@attempt.verify["output"] not in [nil, ""]}
            class="mt-2 max-h-72 overflow-auto rounded-md bg-bm-bg px-3 py-2 font-mono text-[11px] leading-relaxed"
          >{@attempt.verify["output"]}</pre>
          <div :if={is_map(@attempt.verify["review"])} class="mt-2">
            <p class="text-[11px] text-bm-muted">Review</p>
            <p class="mt-1 rounded-md bg-bm-bg px-3 py-2 text-xs leading-relaxed">
              {@attempt.verify["review"]["reason"]}
            </p>
          </div>
          <div :if={is_map(@attempt.verify["check"])} class="mt-2">
            <p class="text-[11px] text-bm-muted">
              Task check <code class="font-mono">{@task.check}</code>
            </p>
            <pre
              :if={@attempt.verify["check"]["output"] not in [nil, ""]}
              class="mt-1 max-h-72 overflow-auto rounded-md bg-bm-bg px-3 py-2 font-mono text-[11px] leading-relaxed"
            >{@attempt.verify["check"]["output"]}</pre>
          </div>
        </details>

        <div
          :if={@undo? and @attempt.status == :accepted and @attempt.actual_writes != []}
          class="flex justify-end"
        >
          <button
            id={"undo-task-#{@task.id}"}
            type="button"
            phx-click="revert_task"
            phx-value-task={@task.id}
            data-confirm={"Put back the files task #{@task.key} changed, as they were before it?"}
            class="rounded-md border border-bm-line px-2.5 py-1 text-[11px] font-medium text-bm-muted transition-colors hover:bg-bm-raised hover:text-bm-text"
          >
            Undo this task
          </button>
        </div>

        <div :if={@item.diffs != []} id={"diff-#{@attempt.id}"} class="space-y-1.5">
          <p class="text-xs font-medium">
            Changes <span class="font-normal text-bm-muted">({length(@item.diffs)})</span>
          </p>
          <details
            :for={diff <- @item.diffs}
            class="group overflow-hidden rounded-md border border-bm-line"
          >
            <summary class="flex cursor-pointer list-none items-center gap-2 px-2.5 py-1.5 font-mono text-[11px] hover:bg-bm-raised">
              <span class={["w-3 text-center font-semibold", change_tone(diff.status)]}>
                {change_letter(diff.status)}
              </span>
              <span class="truncate">{diff.path}</span>
            </summary>
            <.diff text={diff.text} />
          </details>
        </div>
      </div>
    </article>
    """
  end

  # A failed or timed-out verification is why the attempt waits or failed: show it unfolded.
  defp verify_needs_reading?(%{status: status, verify: verify})
       when status in [:held, :failed, :reverted] and is_map(verify),
       do:
         verify["timeout"] == true or (is_integer(verify["exit"]) and verify["exit"] != 0) or
           (is_map(verify["check"]) and verify["check"]["exit"] != 0) or
           match?(%{"verdict" => "reject"}, verify["review"])

  defp verify_needs_reading?(_attempt), do: false

  defp activity_summary(transcript) do
    tools = Enum.count(transcript, &(&1["t"] == "tool"))
    failed = Enum.count(transcript, &(&1["t"] == "tool" and &1["status"] == "error"))
    base = "#{tools} tool #{if tools == 1, do: "call", else: "calls"}"
    if failed > 0, do: base <> ", #{failed} failed", else: base
  end

  defp tool_mark("ok"), do: "✓"
  defp tool_mark("error"), do: "✕"
  defp tool_mark(_running), do: "•"

  defp tool_tone("ok"), do: "text-bm-idle"
  defp tool_tone("error"), do: "text-bm-error"
  defp tool_tone(_running), do: "text-bm-muted"

  defp review_label(%{"verdict" => "approve"}), do: "review approved"
  defp review_label(%{"verdict" => "reject"}), do: "review rejected"
  defp review_label(%{"verdict" => "invalid"}), do: "reviewer changed files"
  defp review_label(_review), do: "not reviewed"

  defp review_tone(%{"verdict" => "approve"}), do: "text-bm-idle"

  defp review_tone(%{"verdict" => verdict}) when verdict in ["reject", "invalid"],
    do: "text-bm-error"

  defp review_tone(_review), do: "text-bm-muted"

  defp terminal?(status),
    do: status in [:accepted, :held, :failed, :cancelled, :needs_reconciliation, :reverted]

  defp verify_label(%{"skipped" => _, "check" => %{"exit" => 0}}),
    do: "no changes; task check passed"

  defp verify_label(%{"skipped" => _, "check" => %{"timeout" => true}}),
    do: "no changes; task check timed out"

  defp verify_label(%{"skipped" => _, "check" => %{"exit" => code}}),
    do: "no changes; task check failed (exit #{code})"

  defp verify_label(%{"exit" => 0, "check" => %{"timeout" => true}}),
    do: "passed; task check timed out"

  defp verify_label(%{"exit" => 0, "check" => %{"exit" => code}}) when code != 0,
    do: "passed; task check failed (exit #{code})"

  defp verify_label(%{"exit" => 0, "check" => %{"exit" => 0}}), do: "passed; task check passed"

  defp verify_label(%{"skipped" => reason}), do: "skipped (#{reason})"
  defp verify_label(%{"timeout" => true}), do: "timed out"
  defp verify_label(%{"exit" => 0}), do: "passed"
  defp verify_label(%{"exit" => code}) when is_integer(code), do: "failed (exit #{code})"
  defp verify_label(_verify), do: "running"

  defp verify_tone(%{"exit" => 0, "check" => %{"exit" => 0}}), do: "text-bm-idle"
  defp verify_tone(%{"exit" => 0, "check" => _failed}), do: "text-bm-error"
  defp verify_tone(%{"exit" => 0}), do: "text-bm-idle"
  defp verify_tone(%{"skipped" => _}), do: "text-bm-muted"
  defp verify_tone(%{"exit" => code}) when is_integer(code), do: "text-bm-error"
  defp verify_tone(%{"timeout" => true}), do: "text-bm-error"
  defp verify_tone(_verify), do: "text-bm-run"

  defp change_letter("added"), do: "A"
  defp change_letter("deleted"), do: "D"
  defp change_letter(_), do: "M"

  defp change_tone("added"), do: "text-bm-idle"
  defp change_tone("deleted"), do: "text-bm-error"
  defp change_tone(_), do: "text-bm-run"

  defp flag_help("undeclared_writes"), do: "Changed files beyond the declared ones"
  defp flag_help("user_owned_writes"), do: "Touched files with the user's uncommitted work"
  defp flag_help("leftover_processes"), do: "Left processes running; BM ended them"
  defp flag_help("verify_changed_files"), do: "The verify command changed files"
  defp flag_help("kept"), do: "Kept by the user as it was"

  defp flag_help("reviewer_wrote"),
    do: "The reviewer changed files while probing; BM held the attempt for your decision"

  defp flag_help("not_reviewed"),
    do: "The reviewer could not run; verification passed, so the change was accepted unreviewed"

  defp flag_help("auto_reverted"),
    do: "The planner's check failed; BM reverted the changes and asked the planner to re-plan"

  defp flag_help(_flag), do: nil
end
