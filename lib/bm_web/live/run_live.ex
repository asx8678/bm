defmodule BmWeb.RunLive do
  @moduledoc """
  One run: its attempts with status, worker summary, flags, verification output and the diff of
  every file each attempt changed, updated live from the workspace coordinator. Actions depend on
  the workspace's lane: Stop while an attempt runs; Keep or Revert when an attempt waits for a
  decision; a next task, Revert of the last change, or Finish when the lane is free.
  """

  use BmWeb, :live_view

  import BmWeb.RunComponents

  alias Bm.Runs
  alias Bm.Workspace.{Coordinator, Git}

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
       page_title: run.goal,
       run: run,
       root: root,
       lane: lane(run),
       latest: List.last(attempts),
       form: to_form(%{"goal" => ""}, as: :next)
     )
     |> stream(:attempts, Enum.map(attempts, &decorate(&1, root)))}
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

      {:noreply,
       socket
       |> assign(lane: lane, latest: attempt, run: reload(socket.assigns.run))
       |> stream_insert(:attempts, decorate(attempt, socket.assigns.root))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:workspace, _root, {:run, %{id: id} = run}},
        %{assigns: %{run: %{id: id}}} = socket
      ) do
    run = %{run | workspace: socket.assigns.run.workspace}
    lane = if run.status in [:active, :paused], do: socket.assigns.lane, else: :finished
    {:noreply, assign(socket, run: run, lane: lane)}
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
        {:noreply, put_flash(socket, :error, "Not reverted: #{inspect(reason)}")}
    end
  end

  def handle_event("finish", _params, socket) do
    case Coordinator.finish_run(socket.assigns.root) do
      {:ok, run} ->
        {:noreply,
         assign(socket, run: %{run | workspace: socket.assigns.run.workspace}, lane: :finished)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not finish the run: #{inspect(reason)}")}
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

  defp act(socket, fun) do
    case fun.(socket.assigns.root) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not possible now: #{inspect(reason)}")}
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-4xl px-4 py-6">
        <header class="flex flex-wrap items-start gap-x-4 gap-y-2">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-bm-muted">
              <.run_status id="run-status" status={@run.status} />
              <span class="font-mono">run #{@run.id}</span>
              <span>·</span>
              <span>started <.ago at={@run.inserted_at} /></span>
              <span :if={@run.finished_at}>·</span>
              <span :if={@run.finished_at}>took {duration(@run.inserted_at, @run.finished_at)}</span>
            </div>
            <h1 id="run-goal" class="mt-1.5 text-lg font-semibold leading-snug">{@run.goal}</h1>
            <p class="mt-1 flex min-w-0 items-baseline gap-1.5 text-[11px]" title={@root}>
              <span class="flex-none font-mono font-medium">{Path.basename(@root)}</span>
              <span class="min-w-0 truncate font-mono text-bm-muted">{@root}</span>
            </p>
          </div>
          <dl id="run-spend" class="text-right">
            <dt class="text-[11px] text-bm-muted">Spent</dt>
            <dd class="font-mono text-sm tabular-nums">
              {money(@run.spent_usd)}<span :if={@run.budget_usd} class="text-bm-muted"> / {money(
                @run.budget_usd
              )}</span>
            </dd>
            <dd :if={@run.spent_unknown > 0} class="text-[11px] text-bm-run">
              + {@run.spent_unknown} without a cost
            </dd>
          </dl>
        </header>

        <.baseline_warning run={@run} />

        <.action_bar lane={@lane} latest={@latest} run={@run} root={@root} form={@form} />

        <ol id="attempts" phx-update="stream" class="mt-6 space-y-4">
          <li
            id="attempts-empty"
            class="hidden rounded-xl border border-dashed border-bm-line p-6 text-center text-xs text-bm-muted only:block"
          >
            No attempts yet.
          </li>
          <li :for={{dom_id, item} <- @streams.attempts} id={dom_id}>
            <.attempt_card item={item} />
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

  attr :lane, :any, required: true
  attr :latest, :any, required: true
  attr :run, :any, required: true
  attr :root, :string, required: true
  attr :form, :any, required: true

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
            <p class="flex-1 text-xs">
              An attempt is running. Its changes are checked when it finishes.
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
              This run is finished. Accepted changes are in your working tree and checkpointed
              under <code class="font-mono">refs/bm/runs/{@run.id}/</code>.
            </p>
            <.link
              id="new-task-link"
              navigate={~p"/?path=#{@root}"}
              class="rounded-md bg-bm-text px-3 py-1.5 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85"
            >
              New task here
            </.link>
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
  slot :inner_block, required: true

  defp action(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-disable-with={@disable_with}
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
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-bm-muted">
          <span>started <.ago at={@attempt.inserted_at} /></span>
          <span :if={terminal?(@attempt.status)}>·</span>
          <span :if={terminal?(@attempt.status)}>
            took {duration(@attempt.inserted_at, @attempt.updated_at)}
          </span>
          <span :if={@attempt.checkpoint_ref}>·</span>
          <span :if={@attempt.checkpoint_ref} class="flex items-center gap-1">
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

        <details :if={@attempt.verify} id={"verify-#{@attempt.id}"} class="group">
          <summary class="flex cursor-pointer list-none items-center gap-2 text-xs">
            <span class="text-bm-muted transition-transform group-open:rotate-90">›</span>
            <span class="font-medium">Verification</span>
            <span class={["font-mono text-[11px]", verify_tone(@attempt.verify)]}>
              {verify_label(@attempt.verify)}
            </span>
          </summary>
          <pre
            :if={@attempt.verify["output"] not in [nil, ""]}
            class="mt-2 max-h-72 overflow-auto rounded-md bg-bm-bg px-3 py-2 font-mono text-[11px] leading-relaxed"
          >{@attempt.verify["output"]}</pre>
        </details>

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

  defp terminal?(status),
    do: status in [:accepted, :held, :failed, :cancelled, :needs_reconciliation, :reverted]

  defp verify_label(%{"skipped" => reason}), do: "skipped (#{reason})"
  defp verify_label(%{"timeout" => true}), do: "timed out"
  defp verify_label(%{"exit" => 0}), do: "passed"
  defp verify_label(%{"exit" => code}) when is_integer(code), do: "failed (exit #{code})"
  defp verify_label(_verify), do: "running"

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
  defp flag_help(_flag), do: nil
end
