<script>
  import {Handle, Position} from "@xyflow/svelte"

  // data: {label, key, status, revision, writes: [..], tool, last_tool, calls,
  //        usage: {input, output, cache_read} | null}
  let {data} = $props()

  const statusLabels = {
    queued: "Queued", running: "Running", accepted: "Accepted",
    failed: "Failed", blocked: "Blocked", cancelled: "Cancelled",
  }

  const formatTokens = count =>
    count == null ? "–" : count >= 1000 ? `${(count / 1000).toFixed(1)}k` : `${count}`
</script>

<div class="task" data-status={data.status}>
  <Handle type="target" position={Position.Left} />
  <div class="strip" aria-hidden="true"></div>

  <div class="body">
    <header>
      <span class="key">{data.key}{data.revision > 1 ? " · re-planned" : ""}</span>
      <span class="badge">{statusLabels[data.status] ?? data.status}</span>
    </header>
    <p class="title" title={data.label}>{data.label}</p>

    {#if data.status === "running"}
      <p class="now" title={data.tool ?? data.last_tool ?? ""}>
        {data.tool ? `Now: ${data.tool}` : data.last_tool ? `Last: ${data.last_tool}` : "Thinking…"}
      </p>
      {#if data.calls}
        <p class="usage">{data.calls} tool {data.calls === 1 ? "call" : "calls"}</p>
      {/if}
      {#if data.usage}
        <p class="usage">in {formatTokens(data.usage.input)} · cached {formatTokens(data.usage.cache_read)} · out {formatTokens(data.usage.output)}</p>
      {/if}
    {:else if data.writes?.length}
      <p class="writes" title={data.writes.join(", ")}>{data.writes.join(", ")}</p>
    {/if}
  </div>

  <Handle type="source" position={Position.Right} />
</div>

<style>
  .task {
    --state: var(--bm-muted);
    position: relative;
    display: flex;
    width: 220px;
    border: 1px solid var(--bm-line);
    border-radius: 9px;
    background: var(--bm-surface);
    color: var(--bm-text);
    overflow: hidden;
    transition: border-color 200ms ease, opacity 200ms ease;
  }

  .task[data-status="running"] { --state: var(--bm-run); border-color: color-mix(in srgb, var(--bm-run) 55%, var(--bm-line)); }
  .task[data-status="accepted"] { --state: var(--bm-idle); }
  .task[data-status="failed"], .task[data-status="blocked"] { --state: var(--bm-error); }
  .task[data-status="cancelled"] { opacity: 0.6; }

  .strip { flex: none; width: 3px; background: var(--state); }

  .task[data-status="running"] .strip {
    background:
      linear-gradient(180deg, transparent 0%, rgb(255 255 255 / 0.55) 50%, transparent 100%) 0 -40px / 100% 40px no-repeat,
      var(--state);
    animation: travel 1.4s linear infinite;
  }

  @keyframes travel { to { background-position: 0 calc(100% + 40px), 0 0; } }

  @media (prefers-reduced-motion: reduce) {
    .task[data-status="running"] .strip { animation: none; background: var(--state); }
  }

  .body { flex: 1; min-width: 0; padding: 7px 10px 7px; }

  header { display: flex; align-items: center; justify-content: space-between; gap: 6px; }

  .key {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--bm-muted);
    font-family: var(--font-mono);
    font-size: 10px;
  }

  .badge {
    flex: none;
    padding: 0 6px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--state) 16%, transparent);
    color: var(--state);
    font-size: 10px;
    font-weight: 600;
  }

  p { margin: 0; }

  .title {
    margin-top: 3px;
    font-size: 12px;
    font-weight: 600;
    line-height: 1.3;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .now, .writes, .usage {
    margin-top: 4px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--bm-muted);
  }

  .now { color: var(--bm-run); }
</style>
