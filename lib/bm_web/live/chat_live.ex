defmodule BmWeb.ChatLive do
  @moduledoc """
  Direct chat with a pi agent (the early prototype). This agent runs with the user's own pi setup
  and is **not** controlled by BM: no profile, policy, snapshots or checkpoints. BM's guarded work
  starts from the Tasks page.
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
       graph: graph(summary),
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

  # Node drags on the canvas are not persisted yet.
  def handle_event("flow_changed", _graph, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:pi, @agent_id, event, summary}, socket) do
    socket = assign(socket, transcript: Transcript.apply(socket.assigns.transcript, event))

    if summary == socket.assigns.agent do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(agent: summary)
       |> push_event("flow:update_node", %{id: @agent_node, data: node_data(summary)})}
    end
  end

  defp graph(summary) do
    %{
      nodes: [
        %{id: @agent_node, type: "agent", position: %{x: 0, y: 0}, data: node_data(summary)}
      ],
      edges: []
    }
  end

  defp node_data(summary), do: Map.put(summary, :label, "pi agent")

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

      <section
        id="agent-flow"
        phx-hook="FlowCanvas"
        phx-update="ignore"
        data-graph={JSON.encode!(@graph)}
        class="hidden min-w-0 flex-1 md:block"
      >
      </section>
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
