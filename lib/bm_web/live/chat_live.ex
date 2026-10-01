defmodule BmWeb.ChatLive do
  @moduledoc """
  Direct chat with a pi agent (the early prototype). This agent runs with the user's own pi setup
  and is **not** controlled by BM: no profile, policy, snapshots or checkpoints. BM's guarded work
  starts from the Tasks page; "Run as a guarded goal" hands the last request over to it.

  The canvas (plan 30, which replaced the separate /flow demo page) shows the agent and its recent
  tool calls live; a click on a node shows its details.
  """

  use BmWeb, :live_view

  alias Bm.Pi.Transcript

  @agent_id "main"
  @agent_node "agent"

  @impl true
  def mount(_params, _session, socket) do
    {transcript, summary} =
      if connected?(socket) do
        Bm.Pi.subscribe(@agent_id)
        {:ok, _pid} = Bm.Pi.ensure_agent(@agent_id)
        %{transcript: transcript, summary: summary} = Bm.Pi.snapshot(@agent_id)
        {transcript, summary}
      else
        {[], %{status: :starting, model: nil, tool: nil, usage: nil, cwd: nil}}
      end

    {:ok,
     assign(socket,
       transcript: transcript,
       agent: summary,
       selected: nil,
       graph: graph(summary, transcript, nil),
       form: to_form(%{"text" => ""})
     )}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        socket = assign(socket, form: to_form(%{"text" => ""}))

        case Bm.Pi.prompt(@agent_id, text) do
          :ok -> {:noreply, socket}
          {:error, _} -> {:noreply, put_flash(socket, :error, "pi is not running.")}
        end
    end
  end

  def handle_event("stop", _params, socket) do
    Bm.Pi.abort(@agent_id)
    {:noreply, socket}
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
    case Bm.Pi.new_session(@agent_id) do
      :ok -> {:noreply, assign(socket, selected: nil)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "pi did not start a new conversation.")}
    end
  end

  @impl true
  def handle_info({:pi, @agent_id, event, summary}, socket) do
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
    "List the LiveView pages and what each one does",
    "Run the tests and summarize the result"
  ]

  @status_labels %{starting: "Starting", idle: "Ready", running: "Working", exited: "Stopped"}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        suggestions: @suggestions,
        status_label: @status_labels[assigns.agent.status]
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
        <div
          :if={@transcript != []}
          id="chat-actions"
          class="flex flex-none flex-wrap items-center gap-1.5 border-b border-bm-line px-3 py-2"
        >
          <.link
            :if={request = last_request(@transcript)}
            id="run-as-goal"
            navigate={~p"/?#{%{goal: request, path: @agent[:cwd] || ""}}"}
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
            <h1 class="text-base font-semibold">Chat with pi</h1>
            <p id="unguarded-note" class="mt-1.5 text-xs leading-relaxed text-bm-muted">
              A direct pi session with your own pi setup. BM does not guard, record or
              checkpoint it; use
              <.link navigate={~p"/"} class="underline underline-offset-2">Tasks</.link>
              for that.
            </p>
            <p :if={@agent[:cwd]} class="mt-1.5 text-xs leading-relaxed text-bm-muted">
              The agent reads, runs and edits code in <code class="font-mono text-[11px] text-bm-text">{@agent.cwd}</code>.
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
          </div>
        </div>

        <.form for={@form} id="chat-form" phx-submit="send" class="flex-none px-3 pb-3">
          <div class="rounded-xl border border-bm-line bg-bm-bg transition-colors focus-within:border-bm-muted">
            <label for="chat-input" class="sr-only">Message the agent</label>
            <textarea
              name={@form[:text].name}
              id="chat-input"
              rows="1"
              placeholder="Ask the agent to read, change or explain code"
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

      <div class="relative hidden min-w-0 flex-1 md:block">
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

  attr :selected, :string, required: true
  attr :agent, :map, required: true
  attr :tool, :any, default: nil

  # The clicked node's details, over the canvas.
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
