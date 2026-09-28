import {mount, unmount} from "svelte"
import FlowCanvas from "../../svelte/FlowCanvas.svelte"

// Mounts Svelte Flow into the hook element.
// Initial graph: JSON in data-graph. Server updates: push_event("flow:set_graph", graph).
// Client edits: pushEvent("flow_changed", graph).
export default {
  mounted() {
    const graph = JSON.parse(this.el.dataset.graph || '{"nodes":[],"edges":[]}')

    this.component = mount(FlowCanvas, {
      target: this.el,
      props: {
        nodes: graph.nodes,
        edges: graph.edges,
        onChange: ({nodes, edges}) =>
          this.pushEvent("flow_changed", {nodes: nodes.map(serializeNode), edges: edges.map(serializeEdge)}),
      },
    })

    this.handleEvent("flow:set_graph", graph => this.component.setGraph(graph))
  },

  destroyed() {
    if (this.component) unmount(this.component)
  },
}

const serializeNode = ({id, type, position, data}) => ({id, type, position, data})
const serializeEdge = ({id, source, target, sourceHandle, targetHandle}) => ({id, source, target, sourceHandle, targetHandle})
