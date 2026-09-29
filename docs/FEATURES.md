# BM features and roadmap

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Second revision, 2026-09-29.

**Core** features are built in order, stage by stage; each stage has an exit gate that must pass
before the next starts. **Optional** features can be added later in any order, when real use shows
they are needed. Sizes are rough: **S** small, **M** medium, **L** large.

---

## Core

### Stage A: foundations and qualification

Make the pieces that exist trustworthy and answer the open questions before building on them.

| # | Feature | Size | Status |
|---|---|---|---|
| A1 | Fix the agent adapter: `new_session`/commands wait for pi's `success`; keep monetary cost; missing usage is *unknown*, not 0; bound the line buffer, pending requests and transcript | S | todo |
| A2 | Split `bm_bridge` into **`bm_planner`** (`propose_task`, `close_plan`) and **`bm_worker`** (`submit_result`) | S | todo |
| A3 | **Authoritative dialogs**: tools send a `bm:` dialog and return the BEAM's answer; the adapter persists before answering; duplicate `request_id`s return the stored outcome; identity comes from the channel | M | todo |
| A4 | `ToolCalls` output becomes **proposals** (UI and read-only preparation only) | S | todo |
| A5 | **Profiles and profile check**: planner / read-only / mutating profiles; self-report on start + `get_state`; mismatch fails closed; pinned pi and Fabric versions | M | todo |
| A6 | **Qualification suite** for the open questions: nested dialogs, `tool_call` blocking in nested calls, denied calls cause no change, missing hooks fail closed, `--tools` restricts nested calls, background jobs | M | todo |
| A7 | Experiment scripts and **sanitized replay fixtures** in the repository | S | todo |

**Exit gate:** qualification results recorded in ARCHITECTURE.md §13–14; every authoritative
operation acknowledged; replay tests pass without a model.

### Stage B: one reliable worker (no planner)

Already useful on its own: "run this task" with safety, verification and a record.

| # | Feature | Size |
|---|---|---|
| B1 | **Runs** with the one-run-per-workspace lock, goal and status | S |
| B2 | **Tasks and attempts** in Postgres with the attempt lifecycle, attempt ids and session epoch fencing | M |
| B3 | **Baseline and dirty-file policy** (user-owned files are never changed, staged or committed) | M |
| B4 | **Snapshots** before/after the attempt → actual write set; compare with the declared set | M |
| B5 | **Settling**: `agent_settled` + no running tool + no descendant processes; process-tree kill on cancel | M |
| B6 | **Verification barrier and checkpoints** under `refs/bm/…` built with a separate index | M |
| B7 | **Conditional rollback** of an attempt (only if contents still match what it produced) | M |
| B8 | **Budget** from confirmed cost with unknown tracked; soft and hard limits | S |
| B9 | **Timeouts** by state (provider wait, running tool, approval wait, stall) and the repeat-call guard | S |
| B10 | **Command policy** in `bm_guard` (git writes, destructive commands; with suggested alternatives) and the **freshness check** on edit/write | M |
| B11 | **UI**: run view with attempt status, per-attempt diff, verification result, budget, stop | M |
| B12 | **Recovery** after restart: freeze, reconcile, then resume / revert / needs-reconciliation | M |

**Exit gate:** tests for dirty files and staged user changes surviving checkpoints and rollback;
rollback refusing newer edits; verification bound to a checkpoint; a failure after a write going
to reconciliation, not a blind retry; missing usage not counted as 0.

### Stage C: planner, plan waves and parallel read-only work

| # | Feature | Size |
|---|---|---|
| C1 | Planner role with **validation** (schema, keys, dependencies, cycles, write sets, budget, generation) → **accepted** tasks | M |
| C2 | **Plan waves** and the **plan-closed** condition | S |
| C3 | **Scheduler**: dependencies on *accepted* results; parallel read-only attempts; one mutation lane | M |
| C4 | **Result inbox**: persist → settle/verify → batch → `follow_up` at the planner's boundary; received / delivered / acknowledged tracked separately | M |
| C5 | Deduplication of streamed and executed observations of the same proposal | S |
| C6 | **Canvas**: planner, workers, tasks and their states live | M |
| C7 | **Benchmark**: the same tasks with a single pi + Fabric, BM with one worker, and BM with read-only helpers; compare verified success, total cost including repairs, wall time and interventions | M |

**Exit gate:** cancelled or invalid planner streams never cause writes; duplicate deliveries have
one effect; routine results never interrupt the planner; the benchmark is recorded.

---

## Optional (add later, any order)

### Parallelism and speed (stages D and E)

| Feature | Precondition | Size |
|---|---|---|
| **Two or more mutating workers**: exclusive file claims (persisted), resource scheduling (lockfiles, build outputs, generated files), hold-and-wait prevention | Stage C exit + every mutation path enforced or isolated; concurrency tests pass | L |
| **Warm worker reuse** (fence → settle → reconcile → confirmed `new_session` → profile check) | Reset qualification tests | M |
| **Streaming read-only preparation** from proposals | Stage C | S |
| **Context reuse** (fork workers from the planner's session) | Measured to be cheaper with zro caching | M |

### Safety and control

| Feature | Size |
|---|---|
| **Approval inbox** in the browser for non-`bm:` dialogs | M |
| **Reviewer role** (read-only, replies silent / message / stop) | M |
| **`ask_planner`** tool for workers | S |
| **Per-task rollback with dependency handling** beyond the V1 conditional rollback | M |
| **Supervisor** (progress and drift checks, Foreman-style) | M |
| Evaluate **Fabric managed-host mode** as an alternative integration | M |

### Usability

| Feature | Size |
|---|---|
| Run history and search | M |
| Small-request shortcut in the UI (straight to stage B flow) | S |
| Short labels for runs and agents (`BM-12`) | S |
| Transcript link per attempt (pi `export_html`) | S |
| CLI client attached to runs | M |
| Front "questioning" agent that sharpens vague requests | M |
| Budget estimates for in-flight work and pricing confidence | S |

### Experimental

| Feature | Size |
|---|---|
| Council / fusion for high-stakes plans | M |
| Learned memory (extraction + consolidation as background jobs) | L |
| Provider failover between zro and coralbricks | M |
| Interactive terminal sessions for workers | M |
| Editor integration (ACP), Slack notifications | M |
| Multiple machines (BEAM distribution) | L |

### Side track: personal pi extensions (independent of BM)

`/btw` side questions, learned memory, command rules with alternatives, stale-write guard, record
and replay; contributions to pi-retry (stall-aware retry), Fabric (`fork` for sub-agents) and
pi-contour (Codex review rubric).

---

## Not planned

Git worktrees and merge queues; pure-Elixir LLM agents; re-implementing Fabric or pi features;
many tiny LLM agents. See [ARCHITECTURE.md §15](ARCHITECTURE.md#15-non-goals).
