<script>
  import {Handle, Position} from "@xyflow/svelte"

  // One tool call of the chat agent. data: {name, detail, status: "running" | "ok" | "error",
  // n (its number in the conversation), selected}
  let {data} = $props()

  const statusLabels = {running: "Running", ok: "Done", error: "Failed"}
</script>

<div class="tool" data-status={data.status} data-selected={data.selected ? "" : undefined}>
  <Handle type="target" position={Position.Left} />
  <div class="strip" aria-hidden="true"></div>
  <div class="body">
    <header>
      <span class="name">{data.name}</span>
      <span class="badge">{statusLabels[data.status] ?? data.status}</span>
    </header>
    {#if data.detail}
      <p class="detail" title={data.detail}>{data.detail}</p>
    {/if}
  </div>
</div>

<style>
  .tool {
    --state: var(--bm-muted);
    display: flex;
    width: 240px;
    border: 1px solid var(--bm-line);
    border-radius: 9px;
    background: var(--bm-surface);
    color: var(--bm-text);
    overflow: hidden;
    cursor: pointer;
    transition: border-color 150ms ease, box-shadow 150ms ease;
  }

  .tool:hover { border-color: var(--bm-muted); }
  .tool[data-selected] { box-shadow: 0 0 0 1.5px var(--bm-text); }
  .tool[data-status="running"] { --state: var(--bm-run); }
  .tool[data-status="ok"] { --state: var(--bm-idle); }
  .tool[data-status="error"] { --state: var(--bm-error); }

  .strip { flex: none; width: 3px; background: var(--state); }

  .tool[data-status="running"] .strip { animation: pulse 1.2s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity: 0.35; } }
  @media (prefers-reduced-motion: reduce) { .tool[data-status="running"] .strip { animation: none; } }

  .body { flex: 1; min-width: 0; padding: 6px 10px; }

  header { display: flex; align-items: center; justify-content: space-between; gap: 6px; }

  .name { font-family: var(--font-mono); font-size: 11px; font-weight: 600; }

  .badge {
    flex: none;
    padding: 0 6px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--state) 16%, transparent);
    color: var(--state);
    font-size: 10px;
    font-weight: 600;
  }

  .detail {
    margin: 2px 0 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--bm-muted);
    font-family: var(--font-mono);
    font-size: 10px;
  }
</style>
