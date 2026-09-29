# BM features and roadmap

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Third revision, 2026-09-29.
The step-by-step plan for the core is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

**Core** is the smallest system that is useful *and* trustworthy: give BM a goal, it plans tasks,
runs them one at a time with a guarded worker, verifies each change, records a checkpoint, and
never damages the user's own work. Core is built in order, with an exit gate per milestone.
**Optional** features are added later, in any order, when real use (or the benchmark) shows they
are needed. Sizes: **S** small, **M** medium, **L** large.

---

## How core was chosen

A feature is core if leaving it out makes BM either **unsafe** (it can lose or corrupt the user's
work, or spend without limit) or **not useful** (no run from goal to verified result). Everything
else is optional, including features that make BM faster or nicer but not safer.

| Question | Core answer | Optional later |
|---|---|---|
| How many writers? | One mutation lane, one attempt at a time | Two or more mutating workers |
| Read-only helpers? | None in core: tasks run sequentially | Parallel read-only workers (only if the benchmark shows a gain) |
| How are changes attributed? | Before/after snapshots of the workspace | + freshness tracking of reads |
| How do we undo? | Conditional revert of the **latest** attempt | Per-task rollback with dependency handling |
| How do we stop runaways? | Hard budget cap, attempt time limit, stall timeout | Soft limits, per-state timeouts, repeat-call guard, in-flight estimates |
| What after a crash? | Minimal recovery: kill leftovers, compare with snapshot, mark for the user | Automatic resume |
| What does the user see? | Run page: tasks, attempts, diffs, verification, spend, Stop / Keep / Revert | Live canvas, history, search, CLI |
| Planner? | One planner, sequential tasks, plan waves, `close_plan` | Reviewer, supervisor, `ask_planner`, council |

---

## Core

### Milestone A: foundations and qualification (done)

| # | Feature | Status |
|---|---|---|
| A1 | Adapter commands wait for pi's `success`; cost kept; missing usage is *unknown*; bounded buffers | done |
| A2 | `bm_planner` / `bm_worker` split | done |
| A3 | Authoritative `bm:` dialogs, persisted and idempotent; identity from the channel | done |
| A4 | Streamed tool calls are proposals only | done |
| A5 | Fabric-free controlled profiles with a fail-closed profile check (D16) | done |
| A6 | Live qualification suite (4/4) | done |

A7 (sanitized replay fixtures) moves to optional: the scripted fake pi covers CI, and the live
suite covers qualification. The Stage A exit gate is amended accordingly (decision recorded in
ARCHITECTURE.md).

### Milestone B: one reliable worker (no planner)

"Run this task on my checkout" with safety, verification and a record. Useful on its own.

| # | Feature | Size | Plan phase |
|---|---|---|---|
| B1 | **Process groups**: pi starts as a session/group leader; settle and stop act on the whole group | S | 1 |
| B2 | **Runs, tasks, attempts** in Postgres; one active run per workspace (DB-enforced); attempt state machine; fencing by attempt id + session epoch | M | 2 |
| B3 | **Git layer**: private-index snapshots (tree ids), write sets from tree diffs, checkpoints under `refs/bm/…`, baseline of user-owned files, conditional restore | M | 3 |
| B4 | **Workspace coordinator**: admit one attempt, guard its tool calls, settle, attribute writes, verify, checkpoint | M | 4 |
| B5 | **Command policy** (minimal): git writes, `setsid`, paths outside the checkout, writes to user-owned files | S | 4 |
| B6 | **Limits**: hard budget cap, attempt time limit, stall timeout | S | 5 |
| B7 | **Revert the latest attempt** (only if its files still hold what it wrote) | S | 5 |
| B8 | **Minimal recovery** after a BEAM restart | S | 5 |
| B9 | **Run page**: start a single task, see attempts, diff, verification output, spend; Stop / Keep / Revert | M | 6 |
| B10 | **Mini-benchmark**: plain pi vs BM with one worker | S | 6 |

**Exit gate:** a live end-to-end run in a scratch repo with a staged user change and a dirty user
file: the task's change is checkpointed and verified, the user's staged change and dirty file are
untouched, a denied or out-of-scope write fails the attempt, a failing verification holds the lane
until Keep/Revert, and a restart mid-attempt ends in `needs_reconciliation`, not a retry. The
benchmark result is recorded.

### Milestone C: planner, sequential tasks

| # | Feature | Size | Plan phase |
|---|---|---|---|
| C1 | **Plan validation** (schema, keys, dependencies, cycles, write sets, user-owned files, budget) | S | 7 |
| C2 | **Planner session**: `propose_task` → accepted/rejected, `close_plan`, plan waves | M | 7 |
| C3 | **Sequential scheduler**: next task whose dependencies are accepted | S | 7 |
| C4 | **Result delivery** to the planner as `follow_up` (received / delivered recorded); bounded retries | M | 7 |
| C5 | **Run page with plan**: planner transcript, task list with dependencies and states | M | 8 |
| C6 | **Benchmark**: plain pi vs BM planner on the same goals | S | 8 |

**Exit gate:** cancelled or invalid planner output never causes writes; duplicate deliveries have
one effect; a run finishes only when the plan is closed and all tasks are terminal; the benchmark
is recorded and decides whether parallel read-only workers are worth building.

---

## Optional (add later, any order)

Each has a precondition; don't start one before it holds.

### Parallelism and speed

| Feature | Precondition | Size |
|---|---|---|
| **Parallel read-only workers** (reader profile exists already) | Milestone C benchmark shows planner-side reading is the bottleneck | M |
| **Two or more mutating workers**: persisted file claims, resource scheduling, hold-and-wait prevention | Parallel readers in use; every mutation path enforced or isolated; concurrency tests | L |
| **Warm worker reuse** (fence → settle → confirmed `new_session` → profile check) | Start-up time measured as significant in the benchmark | M |
| **Streaming read-only preparation** from proposals | Parallel readers | S |
| **Context reuse** (fork workers from the planner's session) | Measured cheaper with zro caching | M |
| **Fabric in workers** through a BM-managed `PI_CODING_AGENT_DIR` | Guard coverage of Fabric's nested calls re-qualified | M |

### Safety and control

| Feature | Size |
|---|---|
| **Freshness check** on edit/write (hash of files the worker read) | M |
| **Per-task rollback** with dependency handling (beyond reverting the latest attempt) | M |
| **Full recovery**: resume attempts that provably changed nothing | M |
| **Refined limits**: soft budget, per-state timeouts (provider / tool / approval / stall), repeat-call guard, in-flight estimates | S–M |
| **Approval inbox** in the browser for non-`bm:` dialogs | M |
| **Reviewer role** (read-only; silent / message / stop) | M |
| **`ask_planner`** tool for workers | S |
| **Supervisor** (progress and drift checks) | M |
| **Sanitized replay fixtures** (A7) with an allowlist sanitizer | S |
| Evaluate **Fabric managed-host mode** | M |

### Usability

| Feature | Size |
|---|---|
| Live **canvas** of planner, workers and tasks (Svelte Flow already present) | M |
| Run history and search | M |
| Short labels for runs and agents (`BM-12`) | S |
| Transcript link per attempt (pi `export_html`) | S |
| Pruning old `refs/bm/…` checkpoints | S |
| CLI client attached to runs | M |
| Front "questioning" agent that sharpens vague requests | M |

### Experimental

| Feature | Size |
|---|---|
| Council / fusion for high-stakes plans | M |
| Learned memory (extraction + consolidation) | L |
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
