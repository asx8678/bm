defmodule BmWeb.HomeLive do
  use BmWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], loading: false, form: to_form(%{"text" => ""}))}
  end

  @impl true
  def handle_event("send", %{"text" => text}, %{assigns: %{loading: false}} = socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        messages = socket.assigns.messages ++ [%{role: "user", content: text}]
        history = Enum.filter(messages, &(&1.role in ["user", "assistant"]))

        {:noreply,
         socket
         |> assign(messages: messages, loading: true, form: to_form(%{"text" => ""}))
         |> start_async(:llm, fn -> Bm.LLM.chat(history) end)}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:llm, {:ok, result}, socket) do
    {:noreply, add_reply(socket, result)}
  end

  def handle_async(:llm, {:exit, reason}, socket) do
    {:noreply, add_reply(socket, {:error, "LLM call crashed: #{inspect(reason)}"})}
  end

  defp add_reply(socket, {:ok, text}), do: append(socket, %{role: "assistant", content: text})
  defp add_reply(socket, {:error, msg}), do: append(socket, %{role: "error", content: msg})

  defp append(socket, message) do
    assign(socket, messages: socket.assigns.messages ++ [message], loading: false)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed top-4 left-4 flex flex-col items-center leading-none">
      <span class="text-2xl font-bold">BM</span>
      <span class="text-[10px]">coding</span>
    </div>

    <div class="mx-auto flex h-screen max-w-3xl flex-col px-4 pt-20 pb-4">
      <div
        id="messages"
        class="flex-1 space-y-4 overflow-y-auto rounded-xl border border-base-300 bg-base-300/50 p-4 font-mono text-sm shadow-inner"
      >
        <div
          :for={msg <- @messages}
          class={[
            "whitespace-pre-wrap rounded-lg px-4 py-2",
            msg.role == "user" && "bg-base-100 ml-auto max-w-[85%] shadow-sm",
            msg.role == "assistant" && "max-w-[85%]",
            msg.role == "error" && "text-error"
          ]}
        >
          {msg.content}
        </div>
        <div :if={@loading} class="px-4 py-2 opacity-60">Thinking…</div>
      </div>

      <.form for={@form} id="chat-form" phx-submit="send" class="mt-4 flex gap-2">
        <textarea
          name={@form[:text].name}
          id="chat-input"
          rows="2"
          placeholder="Ask the coding agent…"
          class="textarea flex-1 rounded-xl border border-base-300 bg-base-300/50 font-mono text-sm shadow-inner"
          disabled={@loading}
          phx-hook=".SubmitOnEnter"
        >{@form[:text].value}</textarea>
        <button type="submit" class="btn btn-primary self-end" disabled={@loading}>Send</button>
      </.form>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              this.el.form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
            }
          })
        }
      }
    </script>
    """
  end
end
