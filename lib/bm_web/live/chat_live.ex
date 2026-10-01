defmodule BmWeb.ChatLive do
  @moduledoc """
  The chat (plan 32): BM's planning assistant, a pi agent in the `:chat` profile owned by
  `Bm.Chat`. It works read-only in the chosen repository and makes plans through its tools
  (`Bm.Plans`); the current plan shows above the messages (the plan board comes in plan 33) and
  its questions as cards to answer.

  The canvas (plan 30) shows the agent and its recent tool calls live; a click on a node shows
  its details.
  """

  use BmWeb, :live_view

  alias Bm.Pi.Transcript

  @agent_node "agent"
  @no_summary %{status: :starting, model: nil, tool: nil, usage: nil, cwd: nil}

  @impl true
  def mount(_params, _session, socket) do
    chat =
      if connected?(socket) do
        Bm.Chat.subscribe()
        Bm.Plans.subscribe_list()
        Bm.Chat.ensure_agent()
      else
        Bm.Chat.state()
      end

    {transcript, summary} = watch(socket, chat.agent_id)

    {:ok,
     assign(socket,
       chat: chat,
       agent_id: chat.agent_id,
       plan: load_plan(chat.plan_id),
       transcript: transcript,
       agent: summary,
       selected: nil,
       graph: graph(summary, transcript, nil),
       form: to_form(%{"text" => ""}),
       answers: %{},
       pane: :plan,
       open: MapSet.new(),
       refining: nil,
       refine_form: to_form(%{"text" => ""}, as: :refine),
       root_form: to_form(%{"path" => chat.root}, as: :root),
       repos: repos()
     )}
  end

  # Follows the agent's pi events (subscribed once per agent; a second subscription would
  # deliver every event twice).
  defp watch(socket, agent_id) do
    if connected?(socket) and is_binary(agent_id) do
      Bm.Pi.subscribe(agent_id)
      snapshot(agent_id)
    else
      {[], @no_summary}
    end
  end

  # An agent that is still starting has nothing to show yet.
  defp snapshot(agent_id) do
    %{transcript: transcript, summary: summary} = Bm.Pi.snapshot(agent_id)
    {transcript, summary}
  catch
    :exit, _ -> {[], @no_summary}
  end

  defp answer(%{"own" => own} = answer) when own != "" do
    case String.trim(own) do
      "" -> answer(Map.delete(answer, "own"))
      own -> own
    end
  end

  defp answer(%{"pick" => pick}) when pick != "", do: pick
  defp answer(_), do: "(no answer: your call)"

  defp task(%{assigns: %{plan: %{tasks: tasks}}}, key), do: Enum.find(tasks, &(&1.key == key))
  defp task(_socket, _key), do: nil

  defp load_plan(nil), do: nil
  defp load_plan(id), do: Bm.Plans.get_plan!(id)

  # Repositories BM knows that still exist, for the picker.
  defp repos, do: for(w <- Bm.Runs.list_workspaces(), File.dir?(w.path), do: w.path)

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        socket = assign(socket, form: to_form(%{"text" => ""}))

        case Bm.Chat.prompt(text) do
          :ok ->
            {:noreply, socket}

          {:error, {:not_ready, _}} ->
            {:noreply,
             put_flash(socket, :error, "The agent is still starting; try again in a moment.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "The agent is not running.")}
        end
    end
  end

  # The question cards are one form: per question a picked option and/or the user's own answer.
  def handle_event("answers_changed", %{"answers" => answers}, socket),
    do: {:noreply, assign(socket, answers: answers)}

  def handle_event("send_answers", params, socket) do
    answers = Map.get(params, "answers", %{})

    text =
      socket.assigns.chat.questions
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {q, i} ->
        "#{q.question}\n→ #{answer(answers[to_string(i)])}"
      end)

    handle_event("send", %{"text" => text}, assign(socket, answers: %{}))
  end

  # Plan 34: the agent questions the plan against the code, round by round.
  def handle_event("grill", _params, socket) do
    handle_event(
      "send",
      %{
        "text" =>
          "Grill this plan: check it against the code and the scope of work, and ask me what only I can decide."
      },
      socket
    )
  end

  def handle_event("pane", %{"pane" => pane}, socket) when pane in ~w(plan activity),
    do: {:noreply, assign(socket, pane: String.to_existing_atom(pane))}

  def handle_event("toggle_task", %{"key" => key}, socket) do
    open = socket.assigns.open
    open = if key in open, do: MapSet.delete(open, key), else: MapSet.put(open, key)
    {:noreply, assign(socket, open: open)}
  end

  # Refine: the user says what should change; the agent changes the task.
  def handle_event("refine", %{"key" => key}, socket),
    do:
      {:noreply,
       assign(socket, refining: key, refine_form: to_form(%{"text" => ""}, as: :refine))}

  def handle_event("cancel_refine", _params, socket),
    do: {:noreply, assign(socket, refining: nil)}

  def handle_event("send_refine", %{"refine" => %{"text" => text}}, socket) do
    case {String.trim(text), task(socket, socket.assigns.refining)} do
      {"", _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, assign(socket, refining: nil)}

      {text, task} ->
        message =
          "Refine task #{task.key} (\"#{task.title}\"): #{text}\n\n" <>
            "Change it with update_task; look at the code again if that is needed."

        handle_event("send", %{"text" => message}, assign(socket, refining: nil))
    end
  end

  # Dig deeper: the agent reads more of the code for one task and proposes choices.
  def handle_event("dig_deeper", %{"key" => key}, socket) do
    case task(socket, key) do
      nil ->
        {:noreply, socket}

      task ->
        message =
          "Dig deeper into task #{task.key} (\"#{task.title}\"). Read the code it touches more " <>
            "closely and make the task concrete with update_task: what exists, the approach, the " <>
            "files, done_when with edge cases and the risks. Where there is a real choice to " <>
            "make, propose the options with ask_user and let me decide."

        handle_event(
          "send",
          %{"text" => message},
          assign(socket, open: MapSet.put(socket.assigns.open, key))
        )
    end
  end

  def handle_event("remove_task", %{"key" => key}, socket) do
    case Bm.Chat.remove_task(key) do
      :ok ->
        {:noreply, assign(socket, open: MapSet.delete(socket.assigns.open, key))}

      {:error, :no_plan} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not removed: #{reason}.")}
    end
  end

  def handle_event("stop", _params, socket) do
    Bm.Chat.stop_turn()
    {:noreply, socket}
  end

  def handle_event("set_root", %{"root" => %{"path" => path}}, socket) do
    case Bm.Chat.set_root(String.trim(path)) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Not a repository BM can use: #{inspect(reason)}")}
    end
  end

  # Node drags on the canvas are not persisted.
  def handle_event("flow_changed", _graph, socket), do: {:noreply, socket}

  # A click on a node selects it (its details show next to the canvas); a second click closes.
  def handle_event("flow_node_clicked", %{"id" => id}, socket) do
    selected = if socket.assigns.selected == id, do: nil, else: id
    {:noreply, socket |> assign(selected: selected) |> push_graph()}
  end

  def handle_event("close_details", _params, socket),
    do: {:noreply, socket |> assign(selected: nil) |> push_graph()}

  def handle_event("new_conversation", _params, socket) do
    case Bm.Chat.new_conversation() do
      :ok -> {:noreply, assign(socket, selected: nil)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "pi did not start a new conversation.")}
    end
  end

  @impl true
  # The chat's state changed: another agent (new repository), a plan, questions, readiness.
  def handle_info({:chat, chat}, socket) do
    socket =
      if chat.agent_id != socket.assigns.agent_id do
        if socket.assigns.agent_id, do: Bm.Pi.unsubscribe(socket.assigns.agent_id)
        {transcript, summary} = watch(socket, chat.agent_id)

        socket
        |> assign(agent_id: chat.agent_id, transcript: transcript, agent: summary, selected: nil)
        |> assign(root_form: to_form(%{"path" => chat.root}, as: :root), repos: repos())
        |> push_graph()
      else
        socket
      end

    socket =
      if chat.status == :ready and socket.assigns.chat.status != :ready,
        do: refresh_agent(socket),
        else: socket

    answers =
      if chat.questions == socket.assigns.chat.questions, do: socket.assigns.answers, else: %{}

    {:noreply, assign(socket, chat: chat, answers: answers, plan: load_plan(chat.plan_id))}
  end

  # A task added or changed (by the agent or the board) flashes on the board.
  def handle_info({:plan, plan_id, event}, %{assigns: %{chat: %{plan_id: plan_id}}} = socket) do
    socket = assign(socket, plan: load_plan(plan_id))

    case event do
      {:task, key} when socket.assigns.pane == :plan ->
        {:noreply, push_event(socket, "bm:scroll_to", %{id: "task-#{key}"})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:plan, _plan_id, _event}, socket), do: {:noreply, socket}

  def handle_info({:pi, id, event, summary}, %{assigns: %{agent_id: id}} = socket) do
    socket = assign(socket, transcript: Transcript.apply(socket.assigns.transcript, event))

    cond do
      # A tool call started or ended, or the conversation was cleared: the canvas changes shape.
      graph_event?(event) ->
        socket = if event == :reset, do: assign(socket, selected: nil), else: socket
        {:noreply, socket |> assign(agent: summary) |> push_graph()}

      true ->
        agent_update(socket, summary)
    end
  end

  def handle_info({:pi, _other, _event, _summary}, socket), do: {:noreply, socket}

  # The agent became ready: its model and status come from its snapshot.
  defp refresh_agent(socket) do
    {_transcript, summary} = snapshot(socket.assigns.agent_id)

    socket
    |> assign(agent: summary)
    |> push_event("flow:update_node", %{id: @agent_node, data: node_data(summary)})
  end

  defp graph_event?({:tool_start, _id, _name, _detail}), do: true
  defp graph_event?({:tool_end, _id, _ok?}), do: true
  defp graph_event?(:reset), do: true
  defp graph_event?(_event), do: false

  defp agent_update(socket, summary) do
    if summary == socket.assigns.agent do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(agent: summary)
       |> push_event("flow:update_node", %{id: @agent_node, data: node_data(summary)})}
    end
  end

  defp push_graph(socket) do
    %{agent: agent, transcript: transcript, selected: selected} = socket.assigns
    push_event(socket, "flow:set_graph", graph(agent, transcript, selected))
  end

  # The agent and its most recent tool calls, newest at the bottom.
  @max_tool_nodes 12

  defp graph(summary, transcript, selected) do
    tools = tool_calls(transcript) |> Enum.take(-@max_tool_nodes)

    agent = %{
      id: @agent_node,
      type: "agent",
      position: %{x: 0, y: 0},
      data: Map.put(node_data(summary), :selected, selected == @agent_node)
    }

    tool_nodes =
      for {{call, n}, row} <- Enum.with_index(tools) do
        id = "tool-#{n}"

        %{
          id: id,
          type: "tool",
          position: %{x: 340, y: row * 70},
          data: %{
            name: call.name,
            detail: call.detail,
            status: call.status,
            n: n,
            selected: selected == id
          }
        }
      end

    edges =
      for node <- tool_nodes, do: %{id: "e-" <> node.id, source: @agent_node, target: node.id}

    %{nodes: [agent | tool_nodes], edges: edges}
  end

  defp tool_calls(transcript) do
    transcript |> Enum.filter(&(&1.role == :tool)) |> Enum.with_index(1)
  end

  defp node_data(summary),
    do: summary |> Map.put(:label, "pi agent") |> Map.put(:horizontal, true)

  defp selected_tool(transcript, "tool-" <> n) do
    case Integer.parse(n) do
      {n, ""} ->
        Enum.find_value(tool_calls(transcript), fn {call, i} -> if i == n, do: {call, n} end)

      _ ->
        nil
    end
  end

  defp selected_tool(_transcript, _id), do: nil

  # The last thing the user asked: what "Run as a guarded goal" hands to the Tasks page.
  defp last_request(transcript) do
    transcript |> Enum.reverse() |> Enum.find_value(&(&1.role == :user && &1.text))
  end

  @suggestions [
    "Explain how this project is structured",
    "Prepare a plan to add a small feature you think is missing",
    "What would you improve first in this code?"
  ]

  @status_labels %{starting: "Starting", idle: "Ready", running: "Working", exited: "Stopped"}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        suggestions: @suggestions,
        status_label:
          case assigns.chat.status do
            {:error, _} -> "Did not start"
            _ -> @status_labels[assigns.agent.status]
          end
      )

    ~H"""
    <Layouts.app flash={@flash} active={:chat} full>
      <:status>
        <div id="agent-status" class="flex min-w-0 items-center gap-1.5 text-xs">
          <span class={["size-1.5 flex-none rounded-full", status_dot(@agent.status)]}></span>
          <span class="font-medium">{@status_label}</span>
          <span :if={@agent.model} class="truncate text-bm-muted">{@agent.model}</span>
        </div>
      </:status>
      <section class="flex w-full min-w-0 flex-col border-bm-line bg-bm-surface md:w-[24rem] md:flex-none md:border-r">
        <.form
          for={@root_form}
          id="repo-form"
          phx-submit="set_root"
          class="flex flex-none items-center gap-1.5 border-b border-bm-line px-3 py-2"
        >
          <label for="repo-input" class="flex-none text-[11px] font-medium text-bm-muted">Repo</label>
          <input
            type="text"
            name={@root_form[:path].name}
            id="repo-input"
            value={@root_form[:path].value}
            list="repo-options"
            spellcheck="false"
            class="min-w-0 flex-1 rounded-md border border-bm-line bg-bm-bg px-2 py-1 font-mono text-[11px] outline-none transition-colors focus:border-bm-muted"
          />
          <datalist id="repo-options">
            <option :for={repo <- @repos} value={repo}></option>
          </datalist>
          <button
            type="submit"
            id="repo-submit"
            title="Plan in this repository: the agent restarts there with a new conversation"
            class="flex-none rounded-md border border-bm-line px-2 py-1 text-[11px] font-medium transition-colors hover:bg-bm-raised"
          >
            Use
          </button>
        </.form>
        <div
          :if={@plan}
          id="current-plan"
          class="flex flex-none items-center gap-2 border-b border-bm-line px-3 py-2 text-xs"
        >
          <span class="flex-none rounded bg-bm-raised px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-bm-muted">
            Plan
          </span>
          <span class="min-w-0 flex-1 truncate font-medium" title={@plan.goal}>{@plan.title}</span>
          <span class="flex-none text-bm-muted">
            {length(@plan.tasks)} {if length(@plan.tasks) == 1, do: "task", else: "tasks"}
          </span>
        </div>
        <div
          :if={@transcript != []}
          id="chat-actions"
          class="flex flex-none flex-wrap items-center gap-1.5 border-b border-bm-line px-3 py-2"
        >
          <.link
            :if={request = last_request(@transcript)}
            id="run-as-goal"
            navigate={~p"/?#{%{goal: request, path: @chat.root}}"}
            title="Open this request on the Tasks page as a guarded goal: planned, checked, reviewed, undoable"
            class="rounded-md bg-bm-text px-2.5 py-1 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85"
          >
            Run as a guarded goal
          </.link>
          <button
            id="new-conversation"
            type="button"
            phx-click="new_conversation"
            data-confirm="Start a new conversation? This one is cleared."
            class="rounded-md border border-bm-line px-2.5 py-1 text-xs font-medium transition-colors hover:bg-bm-raised"
          >
            New conversation
          </button>
        </div>
        <div id="messages" phx-hook=".StickToBottom" class="flex-1 overflow-y-auto px-4 py-4">
          <div :if={@transcript == []} class="flex h-full flex-col justify-center">
            <h1 class="text-base font-semibold">Plan with BM</h1>
            <p id="planning-note" class="mt-1.5 text-xs leading-relaxed text-bm-muted">
              Ask questions about the code or ask for a plan. The agent reads
              <code class="font-mono text-[11px] text-bm-text">{@chat.root}</code>
              but can't change it: plans and their tasks are drafts you review before anything runs.
            </p>
            <div class="mt-4 flex flex-col items-start gap-1.5">
              <button
                :for={suggestion <- @suggestions}
                type="button"
                phx-click="send"
                phx-value-text={suggestion}
                class="rounded-md border border-bm-line px-2.5 py-1 text-left text-xs transition-colors hover:bg-bm-raised focus-visible:outline-2 focus-visible:outline-bm-text"
              >
                {suggestion}
              </button>
            </div>
          </div>

          <div class="space-y-3">
            <.entry :for={entry <- @transcript} entry={entry} />
            <div
              :if={@agent.status == :running}
              class="flex items-center gap-1.5 text-xs text-bm-muted"
            >
              <span class="size-1.5 animate-pulse rounded-full bg-bm-run motion-reduce:animate-none"></span>
              Working
            </div>
            <.form
              :if={@chat.questions != []}
              for={to_form(@answers, as: :answers)}
              id="questions"
              phx-change="answers_changed"
              phx-submit="send_answers"
              class="space-y-2"
            >
              <fieldset
                :for={{q, i} <- Enum.with_index(@chat.questions)}
                id={"question-#{i}"}
                class="rounded-lg border border-bm-line bg-bm-bg p-2.5"
              >
                <legend class="sr-only">Question {i + 1}</legend>
                <p class="text-xs font-medium leading-relaxed">{q.question}</p>
                <div :if={q.options != []} class="mt-2 flex flex-wrap gap-1.5">
                  <label
                    :for={option <- q.options}
                    class="relative cursor-pointer rounded-md border border-bm-line px-2 py-0.5 text-xs transition-colors hover:bg-bm-raised has-checked:border-bm-text has-checked:bg-bm-text has-checked:text-bm-surface has-focus-visible:outline-2 has-focus-visible:outline-bm-text"
                  >
                    <input
                      type="radio"
                      name={"answers[#{i}][pick]"}
                      value={option}
                      checked={get_in(@answers, [to_string(i), "pick"]) == option}
                      class="sr-only"
                    />
                    {option}
                  </label>
                </div>
                <input
                  type="text"
                  name={"answers[#{i}][own]"}
                  value={get_in(@answers, [to_string(i), "own"])}
                  placeholder={if q.options == [], do: "Your answer", else: "Or your own answer"}
                  aria-label={"Your own answer to: #{q.question}"}
                  class="mt-2 block w-full rounded-md border border-transparent bg-transparent px-1.5 py-1 text-xs outline-none transition-colors placeholder:text-bm-muted hover:border-bm-line focus:border-bm-muted"
                />
              </fieldset>
              <div class="flex items-center justify-between gap-2">
                <p class="text-[11px] text-bm-muted">
                  Unanswered questions are left to the agent.
                </p>
                <button
                  id="send-answers"
                  type="submit"
                  class="flex-none rounded-md bg-bm-text px-2.5 py-1 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85"
                >
                  Send answers
                </button>
              </div>
            </.form>
          </div>
        </div>

        <.form for={@form} id="chat-form" phx-submit="send" class="flex-none px-3 pb-3">
          <div class="rounded-xl border border-bm-line bg-bm-bg transition-colors focus-within:border-bm-muted">
            <label for="chat-input" class="sr-only">Message the agent</label>
            <textarea
              name={@form[:text].name}
              id="chat-input"
              rows="1"
              placeholder="Ask about the code or for a plan"
              class="block max-h-48 w-full resize-none bg-transparent px-3 pt-2 text-[13px] leading-relaxed outline-none placeholder:text-bm-muted"
              phx-hook=".Composer"
            >{@form[:text].value}</textarea>
            <div class="flex items-center justify-between gap-2 px-2 pt-0.5 pb-1.5">
              <span class="pl-1 text-[10px] text-bm-muted">Shift + Enter adds a new line</span>
              <div class="flex items-center gap-1.5">
                <button
                  :if={@agent.status == :running}
                  type="button"
                  phx-click="stop"
                  class="rounded-md border border-bm-line px-2 py-0.5 text-xs font-medium transition-colors hover:bg-bm-raised focus-visible:outline-2 focus-visible:outline-bm-text"
                >
                  Stop
                </button>
                <button
                  type="submit"
                  class="rounded-md bg-bm-text px-2.5 py-0.5 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bm-text"
                >
                  Send
                </button>
              </div>
            </div>
          </div>
        </.form>
      </section>

      <div class="relative hidden min-w-0 flex-1 flex-col md:flex">
        <div
          id="pane-switch"
          role="tablist"
          class="flex flex-none items-center gap-1 border-b border-bm-line px-3 py-2"
        >
          <button
            :for={{pane, label} <- [plan: "Plan", activity: "Activity"]}
            id={"pane-#{pane}"}
            type="button"
            role="tab"
            aria-selected={to_string(@pane == pane)}
            phx-click="pane"
            phx-value-pane={pane}
            class={[
              "rounded-md px-2.5 py-1 text-xs font-medium transition-colors",
              if(@pane == pane,
                do: "bg-bm-raised text-bm-text",
                else: "text-bm-muted hover:text-bm-text"
              )
            ]}
          >
            {label}
            <span
              :if={pane == :plan and @plan}
              class="ml-1 rounded bg-bm-bg px-1 text-[10px] tabular-nums text-bm-muted"
            >
              {length(@plan.tasks)}
            </span>
            <span
              :if={pane == :activity and @agent.status == :running}
              class="ml-1 inline-block size-1.5 animate-pulse rounded-full bg-bm-run align-middle motion-reduce:animate-none"
            ></span>
          </button>
        </div>
        <div class="relative min-h-0 flex-1">
          <%!-- The canvas stays mounted (and sized) while the board shows. --%>
          <div class={[
            "absolute inset-0",
            @pane != :activity && "invisible pointer-events-none"
          ]}>
            <section
              id="agent-flow"
              phx-hook="FlowCanvas"
              phx-update="ignore"
              data-graph={JSON.encode!(@graph)}
              class="h-full w-full"
            >
            </section>
            <p
              :if={@selected == nil}
              class="pointer-events-none absolute left-3 top-3 text-[11px] text-bm-muted"
            >
              The agent and its recent tool calls, live. Click a node for its details.
            </p>
            <.details
              :if={@selected}
              selected={@selected}
              agent={@agent}
              tool={selected_tool(@transcript, @selected)}
            />
          </div>
          <div
            :if={@pane == :plan}
            id="plan-board"
            class="absolute inset-0 overflow-y-auto bg-bm-bg px-6 py-5"
          >
            <.board
              plan={@plan}
              open={@open}
              refining={@refining}
              refine_form={@refine_form}
              busy={@agent.status == :running or @chat.status != :ready}
            />
          </div>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          this.resize = () => {
            this.el.style.height = "auto"
            this.el.style.height = `${this.el.scrollHeight}px`
          }
          this.el.addEventListener("input", this.resize)
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault()
              this.el.form.requestSubmit()
            }
          })
          // LiveView reads the form while the submit event bubbles; clear the box after that.
          this.el.form.addEventListener("submit", () => setTimeout(() => {
            this.el.value = ""
            this.resize()
          }))
        },
        updated() { this.resize() }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".StickToBottom">
      export default {
        mounted() { this.el.scrollTop = this.el.scrollHeight },
        beforeUpdate() {
          this.atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
        },
        updated() {
          if (this.atBottom) this.el.scrollTop = this.el.scrollHeight
        }
      }
    </script>
    """
  end

  # The clicked node's details, over the canvas.
  attr :plan, :any, required: true
  attr :open, :any, required: true
  attr :refining, :string, default: nil
  attr :refine_form, :any, required: true
  attr :busy, :boolean, default: false

  defp board(%{plan: nil} = assigns) do
    ~H"""
    <div id="board-empty" class="mx-auto flex h-full max-w-md flex-col justify-center text-center">
      <p class="text-sm font-semibold">No plan yet</p>
      <p class="mt-1.5 text-xs leading-relaxed text-bm-muted">
        Ask in the chat, e.g. <span class="text-bm-text">“Prepare a plan to add CSV export”</span>.
        The agent reads the code first; its plan and tasks appear here, and you refine them
        before anything runs.
      </p>
    </div>
    """
  end

  defp board(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <header id="plan-header" class="mb-5">
        <div class="flex items-center gap-2">
          <h2 class="min-w-0 flex-1 truncate text-lg font-semibold tracking-tight">{@plan.title}</h2>
          <span class="flex-none rounded-full border border-bm-line px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-bm-muted">
            {@plan.status}
          </span>
          <button
            :if={@plan.tasks != []}
            id="grill-plan"
            type="button"
            phx-click="grill"
            disabled={@busy}
            title={
              if @busy,
                do: "The agent is busy",
                else:
                  "The agent checks the plan against the code and the scope, and asks you what only you can decide"
            }
            class="inline-flex flex-none items-center gap-1 rounded-md border border-bm-line px-2.5 py-1 text-xs font-medium transition-colors hover:bg-bm-raised disabled:cursor-not-allowed disabled:opacity-40"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-3.5" /> Grill this plan
          </button>
        </div>
        <p class="mt-1.5 text-[13px] leading-relaxed">{@plan.goal}</p>
        <details :if={@plan.findings not in [nil, ""]} id="plan-findings" class="group mt-2">
          <summary class="cursor-pointer select-none text-xs text-bm-muted transition-colors hover:text-bm-text">
            What the agent found in the code
          </summary>
          <p class="mt-1.5 whitespace-pre-line text-xs leading-relaxed text-bm-muted">
            {@plan.findings}
          </p>
        </details>
      </header>

      <section
        :if={@plan.scope not in [nil, ""]}
        id="plan-scope"
        class="mb-5 rounded-xl border border-bm-line bg-bm-surface px-4 py-3"
      >
        <h3 class="text-[10px] font-semibold uppercase tracking-wide text-bm-muted">Scope of work</h3>
        <p class="mt-1.5 whitespace-pre-line text-xs leading-relaxed">{@plan.scope}</p>
      </section>

      <p
        :if={@plan.tasks == []}
        class="rounded-lg border border-dashed border-bm-line p-4 text-xs text-bm-muted"
      >
        No tasks yet; the agent adds them as it plans.
      </p>

      <ol id="plan-tasks" class="space-y-2.5">
        <.task_card
          :for={{task, i} <- Enum.with_index(@plan.tasks, 1)}
          task={task}
          index={i}
          open={task.key in @open}
          refining={@refining == task.key}
          refine_form={@refine_form}
          busy={@busy}
        />
      </ol>
    </div>
    """
  end

  attr :task, :any, required: true
  attr :index, :integer, required: true
  attr :open, :boolean, default: false
  attr :refining, :boolean, default: false
  attr :refine_form, :any, required: true
  attr :busy, :boolean, default: false

  defp task_card(assigns) do
    ~H"""
    <li
      id={"task-#{@task.key}"}
      class="group rounded-xl border border-bm-line bg-bm-surface transition-[border-color,box-shadow] hover:border-bm-muted/60 hover:shadow-sm"
    >
      <button
        type="button"
        phx-click="toggle_task"
        phx-value-key={@task.key}
        aria-expanded={to_string(@open)}
        class="flex w-full items-start gap-3 px-4 pt-3 text-left"
      >
        <span class="mt-0.5 flex size-5 flex-none items-center justify-center rounded-full bg-bm-raised text-[11px] font-semibold tabular-nums text-bm-muted">
          {@index}
        </span>
        <span class="min-w-0 flex-1">
          <span class="block text-[13px] font-semibold leading-snug">{@task.title}</span>
          <span class="mt-0.5 flex flex-wrap items-center gap-x-2 text-[11px] text-bm-muted">
            <code class="font-mono">{@task.key}</code>
            <span :if={@task.depends_on != []}>after {Enum.join(@task.depends_on, ", ")}</span>
            <span :if={@task.revision > 1}>revised {@task.revision - 1}×</span>
            <span :if={@task.open_questions != []} class="text-bm-run">
              {length(@task.open_questions)} open {if length(@task.open_questions) == 1,
                do: "question",
                else: "questions"}
            </span>
          </span>
        </span>
        <.icon
          name="hero-chevron-down"
          class={[
            "mt-1 size-3.5 flex-none text-bm-muted transition-transform duration-200",
            @open && "rotate-180"
          ]}
        />
      </button>

      <div class="px-4 pb-3 pl-12">
        <p :if={@task.why} class={["mt-1.5 text-xs leading-relaxed", !@open && "line-clamp-2"]}>
          {@task.why}
        </p>
        <div :if={@task.files != []} class="mt-2 flex flex-wrap gap-1">
          <code
            :for={file <- @task.files}
            class="rounded bg-bm-raised px-1.5 py-0.5 font-mono text-[10px] text-bm-muted"
          >
            {file}
          </code>
        </div>

        <dl :if={@open} id={"task-#{@task.key}-details"} class="mt-3 space-y-2.5 text-xs">
          <.field label="What exists" text={@task.existing} />
          <.field label="Approach" text={@task.approach} />
          <.field label="Done when" text={@task.done_when} />
          <.field label="Risks" text={@task.risks} />
          <div :if={@task.open_questions != []}>
            <dt class="text-[10px] font-semibold uppercase tracking-wide text-bm-muted">
              Open questions
            </dt>
            <dd>
              <ul class="mt-1 list-disc space-y-0.5 pl-4 leading-relaxed">
                <li :for={q <- @task.open_questions}>{q}</li>
              </ul>
            </dd>
          </div>
          <div :if={@task.check not in [nil, ""]}>
            <dt class="text-[10px] font-semibold uppercase tracking-wide text-bm-muted">Check</dt>
            <dd>
              <code class="mt-1 inline-block rounded bg-bm-raised px-1.5 py-0.5 font-mono text-[11px]">
                {@task.check}
              </code>
            </dd>
          </div>
        </dl>

        <.form
          :if={@refining}
          for={@refine_form}
          id={"refine-#{@task.key}"}
          phx-submit="send_refine"
          class="mt-3"
        >
          <label for={"refine-#{@task.key}-text"} class="sr-only">What should change?</label>
          <textarea
            name={@refine_form[:text].name}
            id={"refine-#{@task.key}-text"}
            rows="2"
            placeholder="What should change? e.g. split it in two, use the existing helper…"
            phx-mounted={JS.focus()}
            class="block w-full resize-y rounded-lg border border-bm-line bg-bm-bg px-2.5 py-1.5 text-xs leading-relaxed outline-none transition-colors placeholder:text-bm-muted focus:border-bm-muted"
          >{@refine_form[:text].value}</textarea>
          <div class="mt-1.5 flex justify-end gap-1.5">
            <button
              type="button"
              phx-click="cancel_refine"
              class="rounded-md px-2 py-0.5 text-xs text-bm-muted transition-colors hover:text-bm-text"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={@busy}
              class="rounded-md bg-bm-text px-2.5 py-0.5 text-xs font-semibold text-bm-surface transition-opacity hover:opacity-85 disabled:opacity-40"
            >
              Send to the agent
            </button>
          </div>
        </.form>

        <div
          :if={!@refining}
          class="mt-2.5 flex items-center gap-1 opacity-70 transition-opacity group-hover:opacity-100 focus-within:opacity-100"
        >
          <.card_action
            id={"refine-btn-#{@task.key}"}
            icon="hero-pencil-square"
            click="refine"
            key={@task.key}
            disabled={@busy}
            title="Say what should change; the agent updates the task"
          >
            Refine
          </.card_action>
          <.card_action
            id={"dig-btn-#{@task.key}"}
            icon="hero-magnifying-glass"
            click="dig_deeper"
            key={@task.key}
            disabled={@busy}
            title="The agent reads the code for this task more closely and proposes choices"
          >
            Dig deeper
          </.card_action>
          <.card_action
            id={"remove-btn-#{@task.key}"}
            icon="hero-trash"
            click="remove_task"
            key={@task.key}
            confirm={"Remove task “#{@task.title}”?"}
            title="Remove this task from the plan"
            danger
          >
            Remove
          </.card_action>
        </div>
      </div>
    </li>
    """
  end

  attr :label, :string, required: true
  attr :text, :string, default: nil

  defp field(assigns) do
    ~H"""
    <div :if={@text not in [nil, ""]}>
      <dt class="text-[10px] font-semibold uppercase tracking-wide text-bm-muted">{@label}</dt>
      <dd class="mt-0.5 whitespace-pre-line leading-relaxed">{@text}</dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :click, :string, required: true
  attr :key, :string, required: true
  attr :title, :string, default: nil
  attr :confirm, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :danger, :boolean, default: false
  slot :inner_block, required: true

  defp card_action(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@click}
      phx-value-key={@key}
      data-confirm={@confirm}
      disabled={@disabled}
      title={if @disabled, do: "The agent is busy", else: @title}
      class={[
        "inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-40",
        if(@danger,
          do: "text-bm-muted hover:bg-bm-error/10 hover:text-bm-error",
          else: "text-bm-muted hover:bg-bm-raised hover:text-bm-text"
        )
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :selected, :string, required: true
  attr :agent, :map, required: true
  attr :tool, :any, default: nil

  defp details(assigns) do
    ~H"""
    <aside
      id="flow-details"
      class="absolute right-3 top-3 w-80 rounded-lg border border-bm-line bg-bm-surface/95 p-3 text-xs shadow-lg backdrop-blur"
    >
      <div class="flex items-center justify-between gap-2">
        <p class="font-semibold">
          {if @tool, do: "Tool call ##{elem(@tool, 1)}", else: "pi agent"}
        </p>
        <button
          id="close-details"
          type="button"
          phx-click="close_details"
          aria-label="Close"
          class="rounded px-1.5 text-bm-muted transition-colors hover:bg-bm-raised hover:text-bm-text"
        >
          ✕
        </button>
      </div>
      <%= if @tool do %>
        <% {call, _n} = @tool %>
        <dl class="mt-2 grid grid-cols-[5rem_1fr] gap-x-2 gap-y-1">
          <dt class="text-bm-muted">Tool</dt>
          <dd class="font-mono">{call.name}</dd>
          <dt class="text-bm-muted">Status</dt>
          <dd>{%{running: "Running", ok: "Done", error: "Failed"}[call.status] || call.status}</dd>
        </dl>
        <pre
          :if={call.detail not in [nil, ""]}
          class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-md bg-bm-bg px-2 py-1.5 font-mono text-[11px]"
        >{call.detail}</pre>
      <% else %>
        <dl class="mt-2 grid grid-cols-[5rem_1fr] gap-x-2 gap-y-1">
          <dt class="text-bm-muted">Status</dt>
          <dd>{@agent.status}</dd>
          <dt class="text-bm-muted">Model</dt>
          <dd>{@agent.model || "–"}</dd>
          <dt class="text-bm-muted">Folder</dt>
          <dd class="break-all font-mono text-[11px]">{@agent[:cwd] || "–"}</dd>
          <dt class="text-bm-muted">Tokens</dt>
          <dd>{tokens(@agent[:usage])}</dd>
        </dl>
        <p class="mt-2 leading-relaxed text-bm-muted">
          Not guarded by BM: it edits this folder directly. Use "Run as a guarded goal" for work BM
          plans, checks and can undo.
        </p>
      <% end %>
    </aside>
    """
  end

  defp tokens(%{input: input, output: output}) when is_integer(input) and is_integer(output),
    do: "#{input} in · #{output} out"

  defp tokens(_usage), do: "–"

  attr :entry, :map, required: true

  defp entry(%{entry: %{role: :user}} = assigns) do
    ~H"""
    <div
      class="ml-auto w-fit max-w-[85%] whitespace-pre-wrap rounded-xl rounded-br-sm bg-bm-raised px-3 py-1.5 text-[13px] leading-relaxed"
      phx-no-format
    >{@entry.text}</div>
    """
  end

  defp entry(%{entry: %{role: :assistant, text: ""}} = assigns), do: ~H""

  defp entry(%{entry: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="bm-prose">{markdown(@entry.text)}</div>
    """
  end

  defp entry(%{entry: %{role: :tool}} = assigns) do
    ~H"""
    <div class="bm-tool flex items-center gap-1.5 font-mono text-[11px]">
      <span class={["w-3 flex-none text-center", tool_color(@entry.status)]}>
        {tool_icon(@entry.status)}
      </span>
      <span class="flex-none font-medium">{@entry.name}</span>
      <span class="truncate text-bm-muted" title={@entry.detail}>{@entry.detail}</span>
    </div>
    """
  end

  defp entry(%{entry: %{role: :error}} = assigns) do
    ~H"""
    <div
      class="rounded-md border-l-2 border-bm-error bg-bm-error/10 px-2.5 py-1.5 text-xs whitespace-pre-wrap"
      phx-no-format
    >{@entry.text}</div>
    """
  end

  defp entry(%{entry: %{role: :notice}} = assigns) do
    ~H"""
    <div class="text-[11px] text-bm-muted">{@entry.text}</div>
    """
  end

  # MDEx drops raw HTML from the model's output (render: [unsafe: false]).
  defp markdown(text) do
    text
    |> MDEx.to_html!(
      extension: [table: true, strikethrough: true, autolink: true],
      render: [unsafe: false]
    )
    |> Phoenix.HTML.raw()
  end

  defp status_dot(:idle), do: "bg-bm-idle"
  defp status_dot(:running), do: "bg-bm-run animate-pulse motion-reduce:animate-none"
  defp status_dot(:exited), do: "bg-bm-error"
  defp status_dot(_), do: "bg-bm-muted"

  defp tool_icon(:running), do: "•"
  defp tool_icon(:ok), do: "✓"
  defp tool_icon(:error), do: "✕"

  defp tool_color(:running), do: "text-bm-run animate-pulse motion-reduce:animate-none"
  defp tool_color(:ok), do: "text-bm-idle"
  defp tool_color(:error), do: "text-bm-error"
end
