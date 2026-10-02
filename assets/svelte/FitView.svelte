<script>
  import {useSvelteFlow} from "@xyflow/svelte"

  // Fits the view when `layout` changes (nodes were added or removed), without rebuilding the
  // canvas: re-keying SvelteFlow reset the user's zoom and pan on every new node (plan 36.12).
  let {layout} = $props()
  const {fitView} = useSvelteFlow()

  $effect(() => {
    layout
    // New nodes are measured on the next frames; fit after that.
    requestAnimationFrame(() => requestAnimationFrame(() => fitView({maxZoom: 1, padding: 0.15})))
  })
</script>
