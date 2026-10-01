import {mount, unmount} from "svelte"
import FlowCanvas from "../../svelte/FlowCanvas.svelte"

// Mounts Svelte Flow into the hook element.
// Initial graph: JSON in data-graph. Server updates: push_event("flow:set_graph", graph)
// replaces the graph, push_event("flow:update_node", %{id: id, data: data}) merges into one node.
// Client edits: pushEvent("flow_changed", graph); a click on a node: pushEvent("flow_node_clicked", %{id}).
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
        onNodeClick: id => this.pushEvent("flow_node_clicked", {id}),
      },
    })

    this.handleEvent("flow:set_graph", graph => this.component.setGraph(graph))
    this.handleEvent("flow:update_node", ({id, data}) => this.component.updateNode(id, data))
  },

  destroyed() {
    if (this.component) unmount(this.component)
  },
}

const serializeNode = ({id, type, position, data}) => ({id, type, position, data})
const serializeEdge = ({id, source, target, sourceHandle, targetHandle}) => ({id, source, target, sourceHandle, targetHandle})
