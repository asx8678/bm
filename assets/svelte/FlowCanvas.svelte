<script>
  import {SvelteFlow, Background, Controls} from "@xyflow/svelte"
  import "@xyflow/svelte/dist/style.css"
  import AgentNode from "./AgentNode.svelte"
  import TaskNode from "./TaskNode.svelte"

  const nodeTypes = {agent: AgentNode, task: TaskNode}

  // `nodes` and `edges` come from the LiveView; `onChange` reports edits back to it.
  let {nodes: initialNodes = [], edges: initialEdges = [], onChange = () => {}} = $props()

  // The graph is copied once; later server updates arrive through setGraph.
  // svelte-ignore state_referenced_locally
  let nodes = $state.raw(initialNodes)
  // svelte-ignore state_referenced_locally
  let edges = $state.raw(initialEdges)

  // Replaces the graph; nodes the user dragged keep their position.
  // Bumped when nodes are added or removed, so the view fits the new graph.
  let layout = $state(0)

  export function setGraph(next) {
    const moved = new Map(nodes.map(node => [node.id, node.position]))
    const changed = next.nodes.length !== nodes.length || next.nodes.some(node => !moved.has(node.id))
    nodes = next.nodes.map(node => (moved.has(node.id) ? {...node, position: moved.get(node.id)} : node))
    edges = next.edges
    if (changed) layout += 1
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
  {#key layout}
  <SvelteFlow
    bind:nodes
    bind:edges
    {nodeTypes}
    fitView
    fitViewOptions={{maxZoom: 1, padding: 0.15}}
    onnodedragstop={report}
    onconnect={report}
    ondelete={report}
  >
    <Background />
    <Controls showLock={false} />
  </SvelteFlow>
  {/key}
</div>
