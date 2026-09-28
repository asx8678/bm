defmodule BmWeb.FlowLive do
  use BmWeb, :live_view

  @initial_graph %{
    nodes: [
      %{id: "1", type: "input", position: %{x: 0, y: 0}, data: %{label: "Request"}},
      %{id: "2", position: %{x: 0, y: 120}, data: %{label: "Plan"}},
      %{id: "3", type: "output", position: %{x: 0, y: 240}, data: %{label: "Code"}}
    ],
    edges: [
      %{id: "e1-2", source: "1", target: "2"},
      %{id: "e2-3", source: "2", target: "3"}
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, graph: @initial_graph)}
  end

  @impl true
  def handle_event("flow_changed", %{"nodes" => nodes, "edges" => edges}, socket) do
    {:noreply, assign(socket, graph: %{nodes: nodes, edges: edges || []})}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(graph: @initial_graph)
     |> push_event("flow:set_graph", @initial_graph)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed top-4 left-4 z-10 flex flex-col items-center leading-none">
      <span class="text-2xl font-bold">BM</span>
      <span class="text-[10px]">coding</span>
    </div>

    <div class="flex h-screen flex-col px-4 pt-20 pb-4">
      <div class="mb-2 flex items-center justify-between text-sm">
        <span class="opacity-70">
          {length(@graph.nodes)} nodes · {length(@graph.edges)} edges
        </span>
        <button type="button" phx-click="reset" class="btn btn-sm">Reset</button>
      </div>

      <div
        id="flow-canvas"
        phx-hook="FlowCanvas"
        phx-update="ignore"
        data-graph={JSON.encode!(@graph)}
        class="flex-1 overflow-hidden rounded-xl border border-base-300"
      >
      </div>
    </div>
    """
  end
end
