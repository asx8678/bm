defmodule BmWeb.HomeLive do
  @moduledoc """
  Tasks page: start a task in a checkout (milestone B: one guarded worker per task) and see the
  recent runs. A task runs in the workspace's unfinished run, or starts a new one.
  """

  use BmWeb, :live_view

  alias Bm.Runs
  import BmWeb.RunComponents

  alias Bm.Workspace.Coordinator

  @impl true
  def mount(params, _session, socket) do
    runs = Runs.list_recent_runs()
    workspaces = Runs.list_workspaces()

    {:ok,
     socket
     |> assign(
       page_title: "Tasks",
       runs_empty?: runs == [],
       workspaces: workspaces,
       form: default_form(workspaces, params["path"])
     )
     |> stream(:runs, runs)}
  end

  # Prefills the requested workspace (`?path=`) or the last used one, with its verify command.
  defp default_form(workspaces, requested) do
    {path, verify} =
      case Enum.find(workspaces, &(&1.path == requested)) || List.first(workspaces) do
        %{path: path, verify_command: verify} -> {path, verify}
        nil -> {requested || File.cwd!(), nil}
      end

    to_form(
      %{
        "path" => path,
        "goal" => "",
        "writes" => "",
        "verify_command" => verify || "",
        "budget_usd" => ""
      },
      as: :task
    )
  end

  @impl true
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
    <Layouts.app flash={@flash}>
      <div class="mx-auto grid max-w-5xl grid-cols-[minmax(0,1fr)] gap-8 px-4 py-8 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <section aria-labelledby="new-task-title" class="min-w-0">
          <h1 id="new-task-title" class="text-lg font-semibold">New task</h1>
          <p class="mt-1 text-xs leading-relaxed text-bm-muted">
            One guarded worker does the task in your checkout. BM checks every file write and
            command, never touches your uncommitted work or git state, verifies the result and
            records it as a checkpoint.
          </p>

          <.form
            for={@form}
            id="task-form"
            phx-change="validate"
            phx-submit="start"
            class="mt-5 space-y-4 rounded-xl border border-bm-line bg-bm-surface p-4"
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
          <h2 id="runs-title" class="text-sm font-semibold">Recent runs</h2>
          <ol id="runs" phx-update="stream" class="mt-3 space-y-1">
            <li id="runs-empty" class="hidden text-xs text-bm-muted only:block">No runs yet.</li>
            <li :for={{dom_id, run} <- @streams.runs} id={dom_id}>
              <.link
                navigate={~p"/runs/#{run.id}"}
                class="group block rounded-lg border border-transparent px-3 py-2 transition-colors hover:border-bm-line hover:bg-bm-surface focus-visible:outline-2 focus-visible:outline-bm-text"
              >
                <div class="flex items-center gap-2">
                  <.run_status status={run.status} />
                  <span class="min-w-0 flex-1 truncate text-[13px] font-medium">{run.goal}</span>
                </div>
                <div class="mt-1 flex items-center gap-2 text-[11px] text-bm-muted">
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
