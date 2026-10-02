<script>
  import {SvelteFlow, Background, Controls} from "@xyflow/svelte"
  import "@xyflow/svelte/dist/style.css"
  import AgentNode from "./AgentNode.svelte"
  import TaskNode from "./TaskNode.svelte"
  import ToolNode from "./ToolNode.svelte"
  import FitView from "./FitView.svelte"

  const nodeTypes = {agent: AgentNode, task: TaskNode, tool: ToolNode}

  // `nodes` and `edges` come from the LiveView; `onChange` reports edits back to it and
  // `onNodeClick` a click on a node (its id).
  let {
    nodes: initialNodes = [],
    edges: initialEdges = [],
    onChange = () => {},
    onNodeClick = () => {},
  } = $props()

  // The graph is copied once; later server updates arrive through setGraph.
  // svelte-ignore state_referenced_locally
  let nodes = $state.raw(initialNodes)
  // svelte-ignore state_referenced_locally
  let edges = $state.raw(initialEdges)

  // Replaces the graph; only nodes the user dragged keep their position. (Keeping every
  // surviving node's old position stacked the chat's sliding window of tool calls on one row.)
  // Bumped when nodes are added or removed, so the view fits the new graph.
  let layout = $state(0)
  const dragged = new Set()

  export function setGraph(next) {
    const current = new Map(nodes.map(node => [node.id, node.position]))
    const changed = next.nodes.length !== nodes.length || next.nodes.some(node => !current.has(node.id))
    nodes = next.nodes.map(node =>
      dragged.has(node.id) && current.has(node.id) ? {...node, position: current.get(node.id)} : node
    )
    edges = next.edges
    if (changed) layout += 1
  }

  function dragStop({targetNode, nodes: moved}) {
    for (const node of moved ?? [targetNode]) if (node) dragged.add(node.id)
    report()
  }

  export function updateNode(id, data) {
    nodes = nodes.map(node => (node.id === id ? {...node, data: {...node.data, ...data}} : node))
  }

  // Svelte Flow updates the bound state after its callbacks, so report on the next tick.
  function report() {
    queueMicrotask(() => onChange({nodes, edges}))
  }
</script>

<div style="height: 100%; width: 100%;">
  <SvelteFlow
    bind:nodes
    bind:edges
    {nodeTypes}
    fitView
    fitViewOptions={{maxZoom: 1, padding: 0.15}}
    onnodedragstop={dragStop}
    onconnect={report}
    ondelete={report}
    onnodeclick={({node}) => onNodeClick(node.id)}
  >
    <Background />
    <Controls showLock={false} />
    <FitView {layout} />
  </SvelteFlow>
</div>
