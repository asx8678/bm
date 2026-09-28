<script>
  import {SvelteFlow, Background, Controls, MiniMap} from "@xyflow/svelte"
  import "@xyflow/svelte/dist/style.css"

  // `nodes` and `edges` come from the LiveView; `onChange` reports edits back to it.
  let {nodes: initialNodes = [], edges: initialEdges = [], onChange = () => {}} = $props()

  // The graph is copied once; later server updates arrive through setGraph.
  // svelte-ignore state_referenced_locally
  let nodes = $state.raw(initialNodes)
  // svelte-ignore state_referenced_locally
  let edges = $state.raw(initialEdges)

  export function setGraph(next) {
    nodes = next.nodes
    edges = next.edges
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
    fitView
    colorMode="system"
    onnodedragstop={report}
    onconnect={report}
    ondelete={report}
  >
    <Background />
    <Controls />
    <MiniMap />
  </SvelteFlow>
</div>
