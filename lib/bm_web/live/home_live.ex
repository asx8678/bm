defmodule BmWeb.HomeLive do
  @moduledoc """
  Runs page (plan 35: /runs, reached from the chat): start work in a checkout and see the recent runs. Two ways to start:

    * **Goal** (milestone C, plan 8.1): a planner splits the goal into tasks that guarded
      workers run one at a time (`Coordinator.start_goal/3`);
    * **Single task** (milestone B): one guarded worker does the task, in the workspace's
      unfinished run or a new one.
  """

  use BmWeb, :live_view

  alias Bm.Runs
  import BmWeb.RunComponents

  alias Bm.Workspace.Coordinator

  @page 20
  @statuses ~w(active paused done failed cancelled)

  @impl true
  def mount(params, _session, socket) do
    {runs, more?} = Runs.search_runs("", nil, @page)
    workspaces = Runs.list_workspaces()

    {:ok,
     socket
     |> assign(
       page_title: "Runs",
       runs_empty?: runs == [],
       search: to_form(%{"text" => "", "status" => ""}, as: :search),
       runs_limit: @page,
       more_runs?: more?,
       workspaces: workspaces,
       mode: if(params["mode"] == "task", do: :task, else: :goal),
       form: default_form(workspaces, params["path"], params["goal"]),
       goal_form:
         default_form(workspaces, params["path"], params["goal"])
         |> then(&to_form(&1.params, as: :goal)),
       # Goal review (plan 12.3): nil, :running, or %{questions, goal, cost}.
       review: nil
     )
     |> assign(waiting: waiting(runs), live_runs?: unfinished?(runs))
     |> stream(:runs, runs)
     |> then(&if(connected?(&1), do: schedule_refresh(&1), else: &1))}
  end

  # While the list shows an unfinished run, it is reloaded every few seconds: statuses change and
  # a run may start waiting for the user (plan 29).
  @refresh 5_000

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh, @refresh)
    socket
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = if socket.assigns.live_runs?, do: load_runs(socket), else: socket
    {:noreply, schedule_refresh(socket)}
  end

  defp unfinished?(runs), do: Enum.any?(runs, &(&1.status in [:active, :paused]))

  # Unfinished runs that wait for the user: changes for Keep or Revert, or a worker's question.
  # Asks only coordinators that are running; it never starts one.
  defp waiting(runs) do
    for %{status: status} = run <- runs,
        status in [:active, :paused],
        waits?(run),
        into: MapSet.new() do
      run.id
    end
  end

  defp waits?(%{id: id, workspace: workspace}) do
    case Coordinator.state(workspace.path) do
      %{run_id: ^id, lane: {:held, _}} -> true
      %{run_id: ^id, approvals: [_ | _]} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # Prefills the requested workspace (`?path=`) or the last used one, with its verify command.
  # `goal`: a request handed over from the Chat page ("Run as a guarded goal").
  defp default_form(workspaces, requested, goal) do
    # The last used workspace whose checkout still exists (a removed clone is no default).
    {path, verify} =
      case Enum.find(workspaces, &(&1.path == requested)) ||
             Enum.find(workspaces, &File.dir?(&1.path)) do
        %{path: path, verify_command: verify} -> {path, verify}
        nil -> {requested || File.cwd!(), nil}
      end

    to_form(
      %{
        "path" => path,
        "goal" => goal || "",
        "writes" => "",
        "verify_command" => verify || "",
        "budget_usd" => ""
      },
      as: :task
    )
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    {:noreply,
     socket |> assign(search: to_form(params, as: :search), runs_limit: @page) |> load_runs()}
  end

  def handle_event("more_runs", _params, socket) do
    {:noreply, socket |> assign(runs_limit: socket.assigns.runs_limit + @page) |> load_runs()}
  end

  def handle_event("mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, mode: if(mode == "task", do: :task, else: :goal))}
  end

  def handle_event("review_goal", _params, socket) do
    params = socket.assigns.goal_form.params
    goal = String.trim(params["goal"] || "")
    path = String.trim(params["path"] || "")

    if goal == "" do
      form =
        to_form(params,
          as: :goal,
          errors: [goal: {"Describe the goal first.", []}],
          action: :validate
        )

      {:noreply, assign(socket, goal_form: form)}
    else
      {:noreply,
       socket
       |> assign(review: :running)
       |> start_async(:review, fn -> Bm.GoalReview.review(path, goal) end)}
    end
  end

  def handle_event("use_reviewed_goal", params, socket) do
    %{goal: suggested, questions: questions} = socket.assigns.review
    answers = params["answers"] || %{}

    clarifications =
      questions
      |> Enum.with_index()
      |> Enum.flat_map(fn {question, i} ->
        case String.trim(answers[to_string(i)] || "") do
          "" -> []
          answer -> ["- #{question} #{answer}"]
        end
      end)

    goal =
      if clarifications == [],
        do: suggested,
        else: suggested <> "\n\nClarifications:\n" <> Enum.join(clarifications, "\n")

    params = Map.put(socket.assigns.goal_form.params, "goal", goal)
    {:noreply, assign(socket, goal_form: to_form(params, as: :goal), review: nil)}
  end

  def handle_event("dismiss_review", _params, socket), do: {:noreply, assign(socket, review: nil)}

  def handle_event("validate_goal", %{"goal" => params}, socket) do
    {:noreply, assign(socket, goal_form: to_form(params, as: :goal))}
  end

  def handle_event("start_goal", %{"goal" => params}, socket) do
    path = String.trim(params["path"] || "")

    with {:ok, attrs} <- goal_attrs(params),
         {:ok, _pid} <- Coordinator.ensure_started(path),
         {:ok, run} <- Coordinator.start_goal(path, attrs) do
      {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}
    else
      {:error, reason} ->
        {field, message} = explain(reason, path)
        form = to_form(params, as: :goal, errors: [{field, {message, []}}], action: :validate)
        {:noreply, assign(socket, goal_form: form)}
    end
  end

  def handle_event("validate", %{"task" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :task))}
  end

  def handle_event("start", %{"task" => params}, socket) do
    path = String.trim(params["path"] || "")

    with {:ok, attrs} <- task_attrs(params),
         {:ok, _pid} <- Coordinator.ensure_started(path),
         {:ok, attempt} <- Coordinator.run_task(path, attrs) do
      %{run: run} = Runs.attempt_context(attempt)
      {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}
    else
      {:error, reason} ->
        {field, message} = explain(reason, path)
        form = to_form(params, as: :task, errors: [{field, {message, []}}], action: :validate)
        {:noreply, assign(socket, form: form)}
    end
  end

  @impl true
  def handle_async(:review, {:ok, {:ok, review}}, socket),
    do: {:noreply, assign(socket, review: review)}

  def handle_async(:review, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(review: nil)
     |> put_flash(:error, "The goal review did not work: #{review_error(reason)}")}
  end

  def handle_async(:review, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(review: nil)
     |> put_flash(:error, "The goal review stopped: #{inspect(reason)}")}
  end

  defp review_error(:timeout), do: "no answer in time."
  defp review_error(:unreadable_review), do: "the reviewer's reply could not be read; try again."
  defp review_error({:not_a_directory, _}), do: "no such directory."
  defp review_error({:not_repository_root, top}), do: "not the top of a git repository (#{top})."
  defp review_error(other), do: inspect(other)

  # Refills the runs list from the search form and the current page size.
  defp load_runs(socket) do
    params = socket.assigns.search.params
    status = if params["status"] in @statuses, do: String.to_existing_atom(params["status"])
    {runs, more?} = Runs.search_runs(params["text"], status, socket.assigns.runs_limit)

    socket
    |> assign(more_runs?: more?, runs_empty?: runs == [])
    |> assign(waiting: waiting(runs), live_runs?: unfinished?(runs))
    |> stream(:runs, runs, reset: true)
  end

  defp goal_attrs(params) do
    goal = String.trim(params["goal"] || "")
    budget_text = String.trim(params["budget_usd"] || "")

    budget =
      case Float.parse(budget_text) do
        {budget, ""} when budget > 0 -> budget
        _ -> nil
      end

    cond do
      goal == "" ->
        {:error, :no_goal}

      budget_text != "" and budget == nil ->
        {:error, :bad_budget}

      true ->
        {:ok,
         %{goal: goal, verify_command: blank_to_nil(params["verify_command"]), budget_usd: budget}}
    end
  end

  defp task_attrs(params) do
    goal = String.trim(params["goal"] || "")

    budget =
      case Float.parse(String.trim(params["budget_usd"] || "")) do
        {budget, ""} when budget > 0 -> budget
        _ -> nil
      end

    cond do
      goal == "" ->
        {:error, :no_goal}

      String.trim(params["budget_usd"] || "") != "" and budget == nil ->
        {:error, :bad_budget}

      true ->
        {:ok,
         %{
           title: title(goal),
           goal: goal,
           writes: split_files(params["writes"]),
           verify_command: blank_to_nil(params["verify_command"]),
           budget_usd: budget,
           run_goal: title(goal)
         }}
    end
  end

  @doc false
  def title(goal) do
    line = goal |> String.split("\n", trim: true) |> List.first("") |> String.trim()
    if String.length(line) > 80, do: String.slice(line, 0, 79) <> "…", else: line
  end

  @doc false
  def split_files(nil), do: []
  def split_files(text), do: text |> String.split([",", "\n", " "], trim: true) |> Enum.uniq()

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      value -> value
    end
  end

  @doc false
  # Turns a start error into a message for one form field.
  def explain(:no_goal, _path), do: {:goal, "Describe the task."}

  def explain(:goal_run_active, _path),
    do: {:path, "A planner run is active in this workspace; its planner chooses the tasks."}

  def explain(:workspace_busy, _path),
    do: {:path, "This workspace has an unfinished run; finish it (or let it finish) first."}

  def explain(:bad_budget, _path), do: {:budget_usd, "Enter an amount in USD, like 0.50."}

  def explain({:not_a_directory, _}, _path), do: {:path, "No such directory."}

  def explain({:not_repository_root, top}, _path),
    do: {:path, "Not the top of a git repository; this folder is inside #{top}."}

  def explain({:git, "rev-parse", _, _}, _path), do: {:path, "Not a git repository."}

  def explain(:no_verify_command, _path),
    do: {:verify_command, "A verify command is required, e.g. mix precommit or npm test."}

  def explain(:lane_busy, _path),
    do: {:path, "An attempt in this workspace is running or waiting for your decision."}

  def explain(:run_paused, _path),
    do: {:path, "This workspace's run is paused after an interruption; resolve it first."}

  def explain(:budget_exhausted, _path),
    do: {:budget_usd, "The run's budget is spent. Finish the run to start a new one."}

  def explain(%Ecto.Changeset{} = changeset, _path) do
    {:goal, "Could not create the task: #{inspect(changeset.errors)}"}
  end

  def explain(other, _path), do: {:path, "Could not start: #{inspect(other)}"}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        input:
          "block w-full rounded-md border border-bm-line bg-bm-bg px-2.5 py-1.5 text-[13px] text-bm-text outline-none transition-colors placeholder:text-bm-muted/70 focus:border-bm-muted"
      )

    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
      <div class="mx-auto grid max-w-5xl grid-cols-[minmax(0,1fr)] gap-8 px-4 py-8 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <section aria-labelledby="new-task-title" class="min-w-0">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h1 id="new-task-title" class="text-lg font-semibold">
              {if @mode == :goal, do: "New goal", else: "New task"}
            </h1>
            <div
              id="mode-toggle"
              class="flex rounded-lg border border-bm-line bg-bm-bg p-0.5 text-xs"
              role="tablist"
            >
              <button
                :for={{mode, label} <- [goal: "Goal", task: "Single task"]}
                id={"mode-#{mode}"}
                type="button"
                role="tab"
                aria-selected={to_string(@mode == mode)}
                phx-click="mode"
                phx-value-mode={mode}
                class={[
                  "rounded-md px-2.5 py-1 font-medium transition-colors",
                  if(@mode == mode,
                    do: "bg-bm-surface text-bm-text shadow-sm",
                    else: "text-bm-muted hover:text-bm-text"
                  )
                ]}
              >
                {label}
              </button>
            </div>
          </div>
          <p class="mt-1 text-xs leading-relaxed text-bm-muted">
            <%= if @mode == :goal do %>
              A planner splits the goal into small tasks; guarded workers do them one at a time.
              BM checks every file write and command, never touches your uncommitted work or git
              state, verifies each change and records it as a checkpoint.
            <% else %>
              One guarded worker does the task in your checkout. BM checks every file write and
              command, never touches your uncommitted work or git state, verifies the result and
              records it as a checkpoint.
            <% end %>
          </p>

          <.form
            for={@goal_form}
            id="goal-form"
            phx-change="validate_goal"
            phx-submit="start_goal"
            class={[
              "mt-5 space-y-4 rounded-xl border border-bm-line bg-bm-surface p-4",
              @mode != :goal && "hidden"
            ]}
          >
            <.input
              field={@goal_form[:goal]}
              type="textarea"
              label="Goal"
              rows="5"
              placeholder="Add a /health endpoint with a test, and document it in the README."
              class={[@input, "resize-y leading-relaxed"]}
              error_class="border-bm-error"
            />
            <div>
              <.input
                field={@goal_form[:path]}
                id="goal-path"
                label="Repository"
                list="workspaces"
                autocomplete="off"
                class={[@input, "font-mono text-xs"]}
                error_class="border-bm-error"
              />
              <.hint>Top level of a git checkout.</.hint>
            </div>
            <div class="grid gap-4 sm:grid-cols-[minmax(0,1fr)_10rem]">
              <div>
                <.input
                  field={@goal_form[:verify_command]}
                  id="goal-verify"
                  label="Verify command"
                  placeholder="mix precommit"
                  class={[@input, "font-mono text-xs"]}
                  error_class="border-bm-error"
                />
                <.hint>Runs after every task; must pass.</.hint>
              </div>
              <div>
                <.input
                  field={@goal_form[:budget_usd]}
                  id="goal-budget"
                  label="Budget (USD)"
                  placeholder="none"
                  class={[@input, "font-mono text-xs"]}
                  error_class="border-bm-error"
                />
                <.hint>Planner and workers.</.hint>
              </div>
            </div>
            <div class="flex items-center justify-end gap-2">
              <button
                id="review-goal-btn"
                type="button"
                phx-click="review_goal"
                disabled={@review == :running}
                class="rounded-md border border-bm-line bg-bm-surface px-3 py-1.5 text-sm font-medium transition-colors hover:bg-bm-raised disabled:opacity-60"
              >
                {if @review == :running, do: "Reviewing…", else: "Review goal"}
              </button>
              <button
                id="start-goal-btn"
                type="submit"
                phx-disable-with="Starting…"
                class="rounded-md bg-bm-text px-3.5 py-1.5 text-sm font-semibold text-bm-surface transition-opacity hover:opacity-85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bm-text disabled:opacity-60"
              >
                Start planning
              </button>
            </div>
          </.form>

          <section
            :if={@mode == :goal and @review == :running}
            id="goal-review-running"
            class="mt-3 flex items-center gap-2 rounded-xl border border-bm-line bg-bm-surface px-4 py-3 text-xs text-bm-muted"
          >
            <span class="size-1.5 animate-pulse rounded-full bg-bm-run motion-reduce:animate-none"></span>
            A read-only reviewer is looking at the repository and the goal…
          </section>

          <.form
            :if={@mode == :goal and is_map(@review)}
            for={%{}}
            as={:review}
            id="goal-review"
            phx-submit="use_reviewed_goal"
            class="mt-3 space-y-3 rounded-xl border border-bm-line bg-bm-surface p-4"
          >
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="text-sm font-semibold">Goal review</h2>
              <span class="font-mono text-[11px] text-bm-muted">{money(@review.cost)}</span>
            </div>
            <div>
              <p class="text-[11px] text-bm-muted">Suggested goal</p>
              <pre
                id="reviewed-goal"
                class="mt-1 whitespace-pre-wrap rounded-md bg-bm-bg px-3 py-2 font-sans text-xs leading-relaxed"
                phx-no-format
              >{@review.goal}</pre>
            </div>
            <div :if={@review.questions != []} class="space-y-2">
              <p class="text-[11px] text-bm-muted">Questions (answers are added to the goal)</p>
              <label :for={{question, i} <- Enum.with_index(@review.questions)} class="block text-xs">
                <span class="block">{question}</span>
                <input
                  type="text"
                  name={"answers[#{i}]"}
                  id={"review-answer-#{i}"}
                  class="mt-1 block w-full rounded-md border border-bm-line bg-bm-bg px-2.5 py-1.5 text-xs outline-none focus:border-bm-muted"
                />
              </label>
            </div>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="dismiss_review"
                class="rounded-md border border-bm-line px-3 py-1.5 text-xs font-medium transition-colors hover:bg-bm-raised"
              >
                Keep my goal
              </button>
              <button
                id="use-reviewed-goal-btn"
                type="submit"
                class="rounded-md bg-bm-text px-3 py-1.5 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85"
              >
                Use suggested goal
              </button>
            </div>
          </.form>

          <.form
            for={@form}
            id="task-form"
            phx-change="validate"
            phx-submit="start"
            class={[
              "mt-5 space-y-4 rounded-xl border border-bm-line bg-bm-surface p-4",
              @mode != :task && "hidden"
            ]}
          >
            <div>
              <.input
                field={@form[:goal]}
                type="textarea"
                label="Task"
                rows="4"
                placeholder="Add a /health endpoint that returns ok, with a test."
                class={[@input, "resize-y leading-relaxed"]}
                error_class="border-bm-error"
              />
            </div>
            <div>
              <.input
                field={@form[:path]}
                label="Repository"
                list="workspaces"
                autocomplete="off"
                class={[@input, "font-mono text-xs"]}
                error_class="border-bm-error"
              />
              <datalist id="workspaces">
                <option :for={workspace <- @workspaces} value={workspace.path}>
                  {Path.basename(workspace.path)}
                </option>
              </datalist>
              <.hint>
                Top level of a git checkout. Earlier repositories are suggested as you type.
              </.hint>
            </div>
            <div class="grid gap-4 sm:grid-cols-2">
              <div>
                <.input
                  field={@form[:verify_command]}
                  label="Verify command"
                  placeholder="mix precommit"
                  class={[@input, "font-mono text-xs"]}
                  error_class="border-bm-error"
                />
                <.hint>Must pass for a change to be accepted.</.hint>
              </div>
              <div>
                <.input
                  field={@form[:writes]}
                  label="Files to change"
                  placeholder="lib/app/health.ex"
                  class={[@input, "font-mono text-xs"]}
                  error_class="border-bm-error"
                />
                <.hint>Optional; changes to other files are flagged.</.hint>
              </div>
            </div>
            <div class="flex flex-wrap items-end justify-between gap-4">
              <div class="w-40">
                <.input
                  field={@form[:budget_usd]}
                  label="Budget (USD)"
                  placeholder="none"
                  class={[@input, "font-mono text-xs"]}
                  error_class="border-bm-error"
                />
                <.hint>Caps a new run.</.hint>
              </div>
              <button
                id="start-task-btn"
                type="submit"
                phx-disable-with="Starting…"
                class="rounded-md bg-bm-text px-3.5 py-1.5 text-sm font-semibold text-bm-surface transition-opacity hover:opacity-85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bm-text disabled:opacity-60"
              >
                Start task
              </button>
            </div>
          </.form>
        </section>

        <section aria-labelledby="runs-title" class="min-w-0">
          <h2 id="runs-title" class="text-sm font-semibold">Runs</h2>
          <.form
            for={@search}
            id="run-search"
            phx-change="search"
            phx-submit="search"
            class="mt-2 flex gap-2"
          >
            <input
              type="search"
              name={@search[:text].name}
              value={@search[:text].value}
              id="run-search-text"
              placeholder="Search goals and repositories"
              phx-debounce="250"
              autocomplete="off"
              class="min-w-0 flex-1 rounded-md border border-bm-line bg-bm-bg px-2.5 py-1 text-xs outline-none transition-colors placeholder:text-bm-muted/70 focus:border-bm-muted"
            />
            <select
              name={@search[:status].name}
              id="run-search-status"
              aria-label="Status"
              class="rounded-md border border-bm-line bg-bm-bg px-1.5 py-1 text-xs outline-none focus:border-bm-muted"
            >
              <option value="" selected={@search[:status].value in [nil, ""]}>Any</option>
              <option
                :for={status <- ~w(active paused done failed cancelled)}
                value={status}
                selected={@search[:status].value == status}
              >
                {String.capitalize(status)}
              </option>
            </select>
          </.form>
          <ol id="runs" phx-update="stream" class="mt-3 space-y-1">
            <li id="runs-empty" class="hidden text-xs text-bm-muted only:block">No runs yet.</li>
            <li :for={{dom_id, run} <- @streams.runs} id={dom_id}>
              <.link
                navigate={~p"/runs/#{run.id}"}
                class="group block rounded-lg border border-transparent px-3 py-2 transition-colors hover:border-bm-line hover:bg-bm-surface focus-visible:outline-2 focus-visible:outline-bm-text"
              >
                <div class="flex items-center gap-2">
                  <.run_status status={run.status} />
                  <span
                    :if={MapSet.member?(@waiting, run.id)}
                    id={"run-#{run.id}-waits"}
                    class="flex-none rounded-full bg-bm-run/15 px-2 py-0.5 text-[10px] font-semibold text-bm-run"
                  >
                    Needs you
                  </span>
                  <span class="min-w-0 flex-1 truncate text-[13px] font-medium">{run.goal}</span>
                </div>
                <div class="mt-1 flex items-center gap-2 text-[11px] text-bm-muted">
                  <span class="flex-none font-mono">{label(run)}</span>
                  <span class="min-w-0 truncate font-mono" title={run.workspace.path}>
                    {Path.basename(run.workspace.path)}
                  </span>
                  <span class="flex-none">·</span>
                  <.ago at={run.updated_at} class="flex-none" />
                  <span class="ml-auto flex-none font-mono tabular-nums">{money(run.spent_usd)}</span>
                </div>
              </.link>
            </li>
          </ol>
          <button
            :if={@more_runs?}
            id="more-runs-btn"
            type="button"
            phx-click="more_runs"
            class="mt-2 w-full rounded-md border border-bm-line px-3 py-1.5 text-xs text-bm-muted transition-colors hover:bg-bm-surface hover:text-bm-text"
          >
            Show more
          </button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  slot :inner_block, required: true

  defp hint(assigns) do
    ~H"""
    <p class="-mt-1 text-[11px] text-bm-muted">{render_slot(@inner_block)}</p>
    """
  end
end
