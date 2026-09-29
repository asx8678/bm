<script>
  import {Handle, Position} from "@xyflow/svelte"

  // data: {label, status, model, tool, usage: {input, output, cache_read} | null}
  let {data} = $props()

  const statusLabels = {starting: "Starting", idle: "Ready", running: "Working", exited: "Stopped"}

  const formatTokens = count => (count >= 1000 ? `${(count / 1000).toFixed(1)}k` : `${count}`)
</script>

<div class="agent" data-status={data.status}>
  <Handle type="target" position={Position.Top} />
  <div class="strip" aria-hidden="true"></div>

  <div class="body">
    <header>
      <span class="name">{data.label}</span>
      <span class="badge">{statusLabels[data.status] ?? data.status}</span>
    </header>

    <dl class="rows">
      <div>
        <dt>Model</dt>
        <dd>{data.model ?? "Loading"}</dd>
      </div>
      {#if data.tool}
        <div>
          <dt>Running</dt>
          <dd class="tool" title={data.tool}>{data.tool}</dd>
        </div>
      {/if}
    </dl>

    <dl class="tokens">
      <div>
        <dt>Input</dt>
        <dd>{data.usage ? formatTokens(data.usage.input) : "–"}</dd>
      </div>
      <div>
        <dt>Cached</dt>
        <dd>{data.usage ? formatTokens(data.usage.cache_read) : "–"}</dd>
      </div>
      <div>
        <dt>Output</dt>
        <dd>{data.usage ? formatTokens(data.usage.output) : "–"}</dd>
      </div>
    </dl>
  </div>

  <Handle type="source" position={Position.Bottom} />
</div>

<style>
  .agent {
    --state: var(--bm-muted);
    position: relative;
    display: flex;
    width: 200px;
    border: 1px solid var(--bm-line);
    border-radius: 9px;
    background: var(--bm-surface);
    color: var(--bm-text);
    overflow: hidden;
    transition: border-color 200ms ease;
  }

  .agent[data-status="idle"] { --state: var(--bm-idle); }
  .agent[data-status="running"] { --state: var(--bm-run); border-color: color-mix(in srgb, var(--bm-run) 55%, var(--bm-line)); }
  .agent[data-status="exited"] { --state: var(--bm-error); }

  .strip {
    flex: none;
    width: 3px;
    background: var(--state);
  }

  /* While pi works, a band of light travels down the strip. */
  .agent[data-status="running"] .strip {
    background:
      linear-gradient(180deg, transparent 0%, rgb(255 255 255 / 0.55) 50%, transparent 100%) 0 -40px / 100% 40px no-repeat,
      var(--state);
    animation: travel 1.4s linear infinite;
  }

  @keyframes travel {
    to { background-position: 0 calc(100% + 40px), 0 0; }
  }

  @media (prefers-reduced-motion: reduce) {
    .agent[data-status="running"] .strip { animation: none; background: var(--state); }
  }

  .body {
    flex: 1;
    min-width: 0;
    padding: 8px 10px 7px;
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    margin-bottom: 6px;
  }

  .name {
    font-size: 12px;
    font-weight: 600;
  }

  .badge {
    padding: 0 6px;
    border-radius: 999px;
    background: color-mix(in srgb, var(--state) 16%, transparent);
    color: var(--state);
    font-size: 10px;
    font-weight: 600;
  }

  dl { margin: 0; }
  dd { margin: 0; }

  .rows {
    display: grid;
    gap: 2px;
    font-size: 11px;
  }

  .rows > div {
    display: grid;
    grid-template-columns: 48px 1fr;
    gap: 6px;
  }

  .rows dt { color: var(--bm-muted); }

  .tool {
    font-family: var(--font-mono);
    font-size: 10px;
    line-height: 16px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .tokens {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    margin-top: 6px;
    padding-top: 5px;
    border-top: 1px solid var(--bm-line);
  }

  .tokens dt {
    color: var(--bm-muted);
    font-size: 9px;
  }

  .tokens dd {
    font-size: 11px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
</style>
