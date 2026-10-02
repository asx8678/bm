defmodule Bm.Chat do
  @moduledoc """
  The chat (plan 32): one pi agent in the `:chat` profile, working read-only in the chosen
  repository, owned by this process. It answers the agent's requests: the guard's `authorize`
  (read-only policy, `Bm.Policy`) and the plan tools (`create_plan`, `add_task`, `update_task`,
  `remove_task`, `get_plan`, `ask_user`) through `Bm.Plans`. It keeps the repository, the current
  plan and the questions the agent asked, and broadcasts `{:chat, state}` on `topic/0` whenever
  they change. The agent starts lazily and again after the repository changes; its events are
  on `Bm.Pi.subscribe(state.agent_id)`.
  """

  use GenServer
  require Logger

  alias Bm.{Plans, Runs}
  alias Bm.Pi.Profile

  @name __MODULE__

  # Notes saying which plan is current (`plan_note/2` keeps only the newest).
  @plan_notes [
    "the current plan is",
    "the user switched to plan",
    "the user put the current plan aside",
    "the user archived the current plan"
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  def topic, do: "chat"
  def subscribe, do: Phoenix.PubSub.subscribe(Bm.PubSub, topic())

  @doc "The public state: root, workspace_id, agent_id, status, plan_id, questions."
  def state, do: GenServer.call(@name, :state)

  @doc "Starts the agent if it isn't running (the chat page calls this when it opens)."
  def ensure_agent, do: GenServer.call(@name, :ensure_agent)

  @doc "Sends the user's message; the agent's answer arrives as pi events."
  def prompt(text), do: GenServer.call(@name, {:prompt, text}, 35_000)

  def stop_turn, do: GenServer.call(@name, :stop_turn, 125_000)

  @doc "Clears the conversation (pi's new session); the current plan is put aside."
  def new_conversation, do: GenServer.call(@name, :new_conversation, 35_000)

  @doc "Works in another repository from now on: a new agent and conversation there."
  def set_root(path), do: GenServer.call(@name, {:set_root, path})

  @doc """
  Removes task `key` of the current plan for the user (the board's Remove). The agent hears of it
  with the next message.
  """
  def remove_task(key), do: GenServer.call(@name, {:remove_task, key})

  @doc "Makes plan `id` of the current repository the current one (or none with nil)."
  def select_plan(id), do: GenServer.call(@name, {:select_plan, id})

  @doc "Archives plan `id` of the current repository (it leaves the plans list)."
  def archive_plan(id), do: GenServer.call(@name, {:archive_plan, id})

  ## Server

  @impl true
  def init(:ok) do
    # The repository is chosen on first use, not at boot (no database work while starting).
    {:ok,
     %{
       root: nil,
       workspace: nil,
       generation: 0,
       agent_id: nil,
       status: :stopped,
       plan_id: nil,
       questions: [],
       # Changes the user made on the board since the agent's last turn.
       notes: []
     }}
  end

  @impl true
  def handle_call(request, from, %{root: nil} = state) do
    {root, workspace} = default_root()
    handle_call(request, from, restore_plan(%{state | root: root, workspace: workspace}))
  end

  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call(:ensure_agent, _from, state) do
    state = ensure_started(state)
    {:reply, public(state), state}
  end

  def handle_call({:prompt, text}, _from, state) do
    state = ensure_started(state)

    case state.status do
      :ready ->
        state = broadcast(%{state | questions: []})

        {:reply, Bm.Pi.prompt(state.agent_id, with_notes(text, state.notes)),
         %{state | notes: []}}

      status ->
        {:reply, {:error, {:not_ready, status}}, state}
    end
  end

  def handle_call(:stop_turn, _from, %{agent_id: id} = state) when is_binary(id),
    do: {:reply, Bm.Pi.abort(id), state}

  def handle_call(:stop_turn, _from, state), do: {:reply, :ok, state}

  def handle_call(:new_conversation, _from, %{status: :ready} = state) do
    reply = Bm.Pi.new_session(state.agent_id)
    {:reply, reply, broadcast(%{state | plan_id: nil, questions: [], notes: []})}
  end

  def handle_call(:new_conversation, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call({:set_root, path}, _from, state) do
    with {:ok, root} <- Runs.canonical_path(path),
         :ok <- Bm.Workspace.Git.check_root(root),
         {:ok, workspace} <- Runs.ensure_workspace(root) do
      state = stop_agent(state)

      state =
        restore_plan(%{state | root: root, workspace: workspace, questions: [], notes: []})

      state = ensure_started(state)
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:remove_task, _key}, _from, %{plan_id: nil} = state),
    do: {:reply, {:error, :no_plan}, state}

  def handle_call({:remove_task, key}, _from, state) do
    case Plans.remove_task(Plans.get_plan!(state.plan_id), key) do
      {:ok, task} ->
        note = "the user removed task #{key} (\"#{task.title}\")"
        {:reply, :ok, %{state | notes: state.notes ++ [note]}}

      {:error, reason} ->
        {:reply, {:error, explain(reason)}, state}
    end
  end

  def handle_call({:select_plan, nil}, _from, state) do
    state = plan_note(state, "the user put the current plan aside; there is no current plan now")
    {:reply, :ok, broadcast(%{state | plan_id: nil, questions: []})}
  end

  def handle_call({:select_plan, id}, _from, state) do
    case Plans.get_plan!(id) do
      %{workspace_id: workspace_id} = plan when workspace_id == state.workspace.id ->
        state =
          plan_note(state, "the user switched to plan \"#{plan.title}\"; call get_plan to see it")

        {:reply, :ok, broadcast(%{state | plan_id: plan.id, questions: []})}

      _other ->
        {:reply, {:error, :other_repository}, state}
    end
  end

  def handle_call({:archive_plan, id}, _from, state) do
    plan = Plans.get_plan!(id)

    if plan.workspace_id == state.workspace.id do
      {:ok, _} = Plans.update_plan(plan, %{status: :archived})

      state =
        if state.plan_id == plan.id,
          do: broadcast(plan_note(%{state | plan_id: nil}, "the user archived the current plan")),
          else: state

      {:reply, :ok, state}
    else
      {:reply, {:error, :other_repository}, state}
    end
  end

  @impl true
  def handle_info({:started, generation, result}, %{generation: generation} = state) do
    case result do
      {:ok, _report} ->
        {:noreply, broadcast(%{state | status: :ready})}

      {:error, reason} ->
        Logger.warning("chat agent did not start: #{inspect(reason)}")
        {:noreply, broadcast(%{state | status: {:error, reason}, agent_id: nil})}
    end
  end

  # An agent replaced while it was starting (the repository changed): stop it.
  def handle_info({:started, old, {:ok, _report}}, state) do
    Bm.Pi.stop("chat-#{old}")
    {:noreply, state}
  end

  def handle_info({:started, _old, _result}, state), do: {:noreply, state}

  def handle_info({:pi_request, id, request}, %{agent_id: id} = state) do
    {reply, state} = answer(request.op, request.payload || %{}, state)

    if reply["ok"] == false,
      do: Logger.info("chat: #{request.op} refused: #{reply["error"]}")

    Bm.Pi.respond(id, request.dialog_id, reply)
    {:noreply, state}
  end

  # A request of an agent this chat has replaced.
  def handle_info({:pi_request, id, request}, state) do
    Bm.Pi.respond(id, request.dialog_id, %{"ok" => false, "error" => "not_assigned"})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## The agent

  # Still starting: its process may not be registered yet; leave it.
  defp ensure_started(%{status: :starting} = state), do: state

  defp ensure_started(%{status: :ready, agent_id: id} = state) when is_binary(id) do
    if Bm.Pi.alive?(id), do: state, else: start_agent(state)
  end

  defp ensure_started(state), do: start_agent(state)

  # Ids never repeat while BM runs: counting from 1 again after this process restarted would
  # name an agent of the crashed chat (still stopping, or never stopped).
  defp start_agent(state) do
    generation = System.unique_integer([:positive, :monotonic])
    id = "chat-#{generation}"
    chat = self()
    root = state.root

    Task.start(fn ->
      result = Profile.start(id, :chat, owner: chat, cwd: root)
      send(chat, {:started, generation, result})
    end)

    broadcast(%{state | generation: generation, agent_id: id, status: :starting})
  end

  defp stop_agent(%{agent_id: id} = state) when is_binary(id) do
    Bm.Pi.stop(id)
    %{state | agent_id: nil, status: :stopped}
  end

  defp stop_agent(state), do: state

  ## Requests

  defp answer("authorize", payload, state) do
    ctx = %{root: state.root, user_owned: [], mode: :read_only}

    reply =
      case Bm.Policy.authorize(payload["tool"], payload["input"] || %{}, ctx) do
        :allow -> %{"ok" => true, "allow" => true}
        {:deny, reason} -> %{"ok" => true, "allow" => false, "reason" => reason}
      end

    {reply, state}
  end

  defp answer("create_plan", payload, state) do
    case Plans.create_plan(state.workspace, Map.take(payload, ~w(title goal findings))) do
      {:ok, plan} ->
        state = broadcast(%{state | plan_id: plan.id})
        {ok(plan.id), state}

      {:error, changeset} ->
        {error(changeset), state}
    end
  end

  defp answer("update_plan", payload, %{plan_id: id} = state) when is_integer(id) do
    # The model changes what the plan says, never its status.
    attrs = Map.take(payload, ~w(title goal findings scope))
    {result(Plans.update_plan(Plans.get_plan!(id), attrs), id), state}
  end

  defp answer("ask_user", %{"questions" => [_ | _] = questions}, state) do
    questions =
      for q <- Enum.take(questions, 5), is_binary(q["question"]) do
        %{question: q["question"], options: Enum.filter(List.wrap(q["options"]), &is_binary/1)}
      end

    {%{"ok" => true}, broadcast(%{state | questions: questions})}
  end

  defp answer("ask_user", _payload, state),
    do: {%{"ok" => false, "error" => "give one to five questions"}, state}

  defp answer(op, payload, %{plan_id: nil} = state)
       when op in ~w(update_plan add_task update_task remove_task get_plan) do
    _ = payload
    {%{"ok" => false, "error" => "there is no current plan: call create_plan first"}, state}
  end

  defp answer("get_plan", _payload, state), do: {ok(state.plan_id), state}

  defp answer("add_task", payload, state) do
    plan = Plans.get_plan!(state.plan_id)
    attrs = Map.drop(payload, ["before"])
    {result(Plans.add_task(plan, attrs, payload["before"]), plan.id), state}
  end

  defp answer("update_task", %{"key" => key} = payload, state) do
    plan = Plans.get_plan!(state.plan_id)
    {result(Plans.update_task(plan, key, Map.delete(payload, "key")), plan.id), state}
  end

  defp answer("remove_task", %{"key" => key}, state) do
    plan = Plans.get_plan!(state.plan_id)
    {result(Plans.remove_task(plan, key), plan.id), state}
  end

  defp answer(_op, _payload, state), do: {%{"ok" => false, "error" => "not_allowed"}, state}

  defp result({:ok, _}, plan_id), do: ok(plan_id)
  defp result(:ok, plan_id), do: ok(plan_id)
  defp result(error, _plan_id), do: error(error)

  # The model hears the plan as it now stands after every change.
  defp ok(plan_id), do: %{"ok" => true, "plan" => describe(Plans.get_plan!(plan_id))}

  defp error({:error, %Ecto.Changeset{} = changeset}), do: error(changeset)

  defp error(%Ecto.Changeset{errors: errors}) do
    text = Enum.map_join(errors, "; ", fn {field, {message, _}} -> "#{field} #{message}" end)
    %{"ok" => false, "error" => text}
  end

  defp error({:error, reason}), do: %{"ok" => false, "error" => explain(reason)}

  defp explain(:no_such_task), do: "there is no task with that key in the current plan"
  defp explain(:dependency_cycle), do: "these dependencies would make a cycle"

  defp explain({:unknown_dependencies, keys}),
    do: "unknown tasks in depends_on: #{Enum.join(keys, ", ")}"

  defp explain({:bad_dependencies, keys}), do: "a task can't depend on itself: #{inspect(keys)}"

  defp explain({:dependents, keys}),
    do: "#{Enum.join(keys, ", ")} depend on it; change them first"

  defp explain({:bad_files, files}),
    do: "files must be relative paths inside the repository: #{inspect(files)}"

  defp explain({:check_refused, sentence}), do: sentence

  defp explain(other), do: inspect(other)

  @doc "The plan as text for the model: its goal and every task with its key and dependencies."
  def describe(plan) do
    tasks =
      plan.tasks
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {t, i} ->
        deps = if t.depends_on == [], do: "", else: " (after #{Enum.join(t.depends_on, ", ")})"
        "#{i}. #{t.key}: #{t.title}#{deps}"
      end)

    tasks = if tasks == "", do: "(no tasks yet)", else: tasks
    scope = if plan.scope in [nil, ""], do: "", else: "\nScope:\n#{plan.scope}"

    "Current plan \"#{plan.title}\" (#{plan.status}). Goal: #{plan.goal}#{scope}\nTasks:\n#{tasks}"
  end

  # The repository's latest plan becomes current again (after a restart or a repository change);
  # the agent's conversation is new, so it is told.
  defp restore_plan(state) do
    case Plans.latest_plan(state.workspace.id) do
      nil ->
        %{state | plan_id: nil}

      plan ->
        plan_note(
          %{state | plan_id: plan.id},
          "the current plan is \"#{plan.title}\"; call get_plan to see it"
        )
    end
  end

  defp note(state, text), do: %{state | notes: state.notes ++ [text]}

  # A newer word on which plan is current replaces the older ones.
  defp plan_note(state, text) do
    notes = Enum.reject(state.notes, &String.starts_with?(&1, @plan_notes))
    note(%{state | notes: notes}, text)
  end

  defp with_notes(text, []), do: text

  defp with_notes(text, notes),
    do: "[On the plan board since your last turn: #{Enum.join(notes, "; ")}.]\n\n#{text}"

  ## State

  defp public(state),
    do:
      Map.take(state, [:root, :agent_id, :status, :plan_id, :questions])
      |> Map.put(:workspace_id, state.workspace && state.workspace.id)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Bm.PubSub, topic(), {:chat, public(state)})
    state
  end

  # The last used workspace that still exists, else BM's own directory.
  defp default_root do
    case Enum.find(Runs.list_workspaces(), &File.dir?(&1.path)) do
      nil ->
        root = File.cwd!()
        {:ok, workspace} = Runs.ensure_workspace(root)
        {root, workspace}

      workspace ->
        {workspace.path, workspace}
    end
  end
end
