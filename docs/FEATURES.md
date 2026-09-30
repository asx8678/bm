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
| Read-only helpers? | None in core: tasks run sequentially; planner and reader get a guarded read-only bash | Parallel read-only workers (only if the benchmark shows a gain) |
| How are changes attributed? | Before/after snapshots of the workspace | + freshness tracking of reads |
| How do we undo? | Conditional revert of the **latest** attempt | Per-task rollback with dependency handling |
| How do we stop runaways? | Hard budget cap, attempt time limit, stall timeout | Soft limits, per-state timeouts, repeat-call guard, in-flight estimates |
| What after a crash? | Minimal recovery: kill leftovers, compare with snapshot, mark for the user | Automatic resume |
| What does the user see? | Run page: tasks, attempts, diffs, verification, spend, Stop / Keep / Revert | Live canvas, history, search, CLI |
| Planner? | One planner process, sequential tasks, plan waves, `close_plan`, per-task check | Reviewer, supervisor, `ask_planner`, council |

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

**Status: done (2026-09-29).** Exit gate passed (`test/live/milestone_b_test.exs`); benchmark in
[BENCHMARK.md](BENCHMARK.md).

**Exit gate:** a live end-to-end run in a scratch repo with a staged user change and a dirty user
file: the task's change is checkpointed and verified, the user's staged change and dirty file are
untouched, a denied or out-of-scope write fails the attempt, a failing verification holds the lane
until Keep/Revert, and a restart mid-attempt ends in `needs_reconciliation`, not a retry. The
benchmark result is recorded.

### Milestone B.5: hardening before the planner

Added after the milestone B review (2026-09-29); plan phase 6.6.

| # | Feature | Size | Plan step |
|---|---|---|---|
| B11 | **UI checked in a browser** (chat page and agent canvas kept at the user's request) | S | 6.6.1–6.6.2 |
| B12 | **Baseline verification** at run start, shown when the checkout already fails | S | 6.6.3 |
| B13 | **Harder benchmark** with user-owned and generated files; write-set declaration measured (open question 7) | S | 6.6.4 |
| B14 | **Guarded read-only bash** for planner and reader (policy in read-only mode + snapshot check) | M | 6.6.5 |

**Status: done (2026-09-29).** Benchmark in [BENCHMARK.md](BENCHMARK.md): write sets declared
exactly in 11/11 runs; plain pi overwrote the user's dirty file 3/3, BM 0/3.

### Milestone C: planner, sequential tasks

| # | Feature | Size | Plan phase |
|---|---|---|---|
| C1 | **Plan validation** (schema, keys, dependencies, cycles, write sets, user-owned files, budget, check command) | S | 7 |
| C2 | **Planner process** per run: `propose_task` → accepted/rejected, `close_plan`, plan waves; planner spend in the budget; a planner that changes files holds the run | M | 7 |
| C3 | **Sequential scheduler**: next task whose dependencies are accepted | S | 7 |
| C4 | **Dependency context**: workers get the summary and write set of accepted dependencies | S | 7 |
| C5 | **Result delivery** to the planner as `follow_up` (received / delivered recorded); one re-plan per failed task | M | 7 |
| C6 | **Task check**: optional per-task command run after the workspace verify; both must pass | S | 7 |
| C7 | **Runaway planner limits** (rejections per wave, waves per run, plan timeout) and **planner recovery** (run paused, Resume planning / Finish) | S | 7 |
| C8 | **Run page with plan**: goal form, planner transcript, task list with dependencies and states | M | 8 |
| C9 | **Benchmark**: plain pi vs BM planner on multi-step goals touching user-owned files | S | 8 |

**Status: done (2026-09-30).** Gate passed live (plan 8.2); goals benchmark in
[BENCHMARK_GOALS.md](BENCHMARK_GOALS.md). Decision: parallel read-only workers are not next;
cutting per-goal overhead is. **Corrected after measuring (plan phase 9):** worker start-up is
0.3–0.45 s per task, so warm reuse is not worth it; the planner's round-trips were the cost,
cut by a one-call `propose_plan` and no final planner turn after a clean plan.

**Exit gate:** cancelled or invalid planner output never causes writes; a planner that writes
holds the run; duplicate deliveries have one effect; a run finishes only when the plan is closed
and all tasks are terminal; a BEAM restart during planning leaves the run paused, not retried;
the benchmark is recorded and decides whether parallel read-only workers are worth building.

---

## Optional (add later, any order)

Each has a precondition; don't start one before it holds.

### Parallelism and speed

| Feature | Precondition | Size |
|---|---|---|
| **Parallel read-only workers** (reader profile exists already) | Milestone C benchmark shows planner-side reading is the bottleneck | M |
| **Two or more mutating workers**: persisted file claims, resource scheduling, hold-and-wait prevention | Parallel readers in use; every mutation path enforced or isolated; concurrency tests | L |
| **Warm worker reuse** (fence → settle → confirmed `new_session` → profile check) | Start-up time measured as significant in the benchmark. **Measured 2026-09-30: not significant** (0.3–0.45 s per task, ≈1 s of a 22–28 s goal run); not planned for now | M |
| **Streaming read-only preparation** from proposals | Parallel readers | S |
| **Context reuse** (fork workers from the planner's session) | Measured cheaper with zro caching | M |
| **Fabric in workers** through a BM-managed `PI_CODING_AGENT_DIR` | Guard coverage of Fabric's nested calls re-qualified | M |

### Safety and control

| Feature | Size |
|---|---|
| **Freshness check** on edit/write (hash of files the worker read) — **done** for whole-file writes against the attempt's start (plan 13.2); files edited during a run are protected (13.1) | M |
| **Per-task rollback** with dependency handling (beyond reverting the latest attempt) — reverting a **whole finished run** (plan 11.4) and **one task of a finished run** with dependency checks (plan 13.3) are done; undo **during a run** (paused goal run, active single-task run; plan 23.1, D28) is done | M |
| **Full recovery**: resume attempts that provably changed nothing — **done for goal runs** after a restart (plan 21, D27): the task is queued again and planning resumes by itself; attempts that changed files still wait for the user | M |
| **Refined limits**: soft budget, per-state timeouts (provider / tool / approval / stall), repeat-call guard, in-flight estimates — repeat-call guard, tool timeout and soft budget **done** (plan 11.5); a silent model stops planner and review turns too (plan 23.2); approval timeout with the inbox (plan 24.1); in-flight estimates not | S–M |
| **Approval inbox** in the browser for non-`bm:` dialogs — **done** for workers' attempts (plan 24.1, D29) | M |
| **Reviewer role** (read-only; silent / message / stop) — **done** as a review before accepting each goal-run task (plan 14.1, D25) | M |
| **`ask_planner`** tool for workers — **done** (plan 12.2, D24); seen with the fake pi, no real worker has asked yet | S |
| **Supervisor** (progress and drift checks) — **done** as rules without model calls (plan 25): steer the worker on a write outside its files or when it changes nothing for a while, cancel if it still doesn't; pause a goal run after 3 attempts in a row without an accepted task | M |
| **Sanitized replay fixtures** (A7) with an allowlist sanitizer | S |
| Evaluate **Fabric managed-host mode** | M |

### Usability

| Feature | Size |
|---|---|
| Live **canvas** of planner, workers and tasks — **done 2026-09-30** (plan 10.1) | M |
| Run history and search — **done 2026-09-30** (plan 10.5): text and status filter, paging | M |
| Short labels for runs and agents (`BM-12`) — runs **done** (plan 12.1) | S |
| Transcript per attempt — **done 2026-09-30** as a stored compact transcript and an Activity fold (plan 10.4), not pi `export_html` | S |
| Pruning old `refs/bm/…` checkpoints — **done 2026-09-30** (plan 10.3) | S |
| CLI client attached to runs — **done** as `mix bm.attach` (plan 24.2), with `mix bm.pause`, `bm.resume`, `bm.undo` and a status filter for `mix bm.runs` (plan 28, made by BM itself) | M |
| Front "questioning" agent that sharpens vague requests — **done** as goal review in the Goal form (plan 12.3) | M |

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
