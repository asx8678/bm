# BM features and priorities

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Revised 2026-09-29.

**How to read this:** build top to bottom. **P0** is required before BM does its job at all. **P1**
makes it safe and pleasant to use on real repositories. **P2** and **P3** are optional: build one only
when real use shows it's needed. Sizes are rough: **S** ≈ a small module or extension, **M** ≈ a few
modules plus tests, **L** ≈ a subsystem.

## P0: core (must have, build first)

Without these, BM can't plan, run and deliver work safely. Items are in build order.

| # | Feature | Why it's essential | Depends on | Size | Status |
|---|---|---|---|---|---|
| 0.1 | **pi RPC agent** (`Bm.Pi.Agent`): Port, events, env, raw log, `new_session` | Everything talks to pi through it | none | M | **done** |
| 0.2 | **Streamed tool-call assembler** (`Bm.Pi.ToolCalls`) | Tasks start while the plan is still being written (GLM sends `toolcall_end` late) | 0.1 | S | **done** |
| 0.3 | **Bridge extension** (`bm_bridge`: `add_task`, `submit_result`, `bm:` notify) | How the planner hands out work and workers report back | 0.1 | S | **done** |
| 0.4 | **Runs** (`Bm.Runs`): one run per request with goal and status | The unit everything else hangs off | none | S | todo |
| 0.5 | **Router + task records** (`Bm.Router`, `Bm.Tasks` in Postgres) | Turns streamed `add_task` calls into durable tasks | 0.2, 0.4 | M | todo |
| 0.6 | **Worker pool** (`Bm.Workers.Pool`): 2 warm workers, reuse via `new_session`, stall watchdog | Runs tasks without paying start-up cost each time | 0.1 | M | todo |
| 0.7 | **Task brief and results loop**: worker prompt template; `submit_result` → `follow_up` to the planner | Closes the loop from plan to result | 0.3, 0.5, 0.6 | S | todo |
| 0.8 | **Scheduler** (`Bm.Scheduler`): dependencies met **and** declared files disjoint | Parallel work without two tasks on the same files | 0.5 | S | todo |
| 0.9 | **File claims** (`bm_claims` extension + `Bm.Claims`) | Stops a second writer at edit time; the core of the shared-checkout model | 0.6 | M | todo, **verify first** (open question 1) |
| 0.10 | **BEAM-owned git** (`Bm.Git`): per-task commit of claimed files, per-task revert; workers blocked from git writes | Clean history and undo without worktrees | 0.9 | M | todo |
| 0.11 | **Verifier** (`Bm.Verifier`): compile + tests after each batch; failures to the planner | Catches breakage that single workers can't see | 0.10 | S | todo |
| 0.12 | **Basic limits** (`Bm.Limits`): run budget from `usage.cost`, per-task timeout, stop-all | Parallel agents multiply cost; a runaway run must be stoppable | 0.6 | S | todo |
| 0.13 | **Basic UI**: canvas with planner and worker nodes, task board, stop button | You must see what the agents are doing | 0.5, 0.6 | M | partly (chat + one agent node) |

**Exit criteria for P0:** a real request is planned, runs on 2 workers in one checkout without
writing the same file twice, each task becomes its own commit, verification runs, the planner
summarizes, and the run stays inside its budget.

## P1: high value, right after the core

These make BM safe to leave running and nicer to use. Build them next, roughly in this order.

| # | Feature | Why | Depends on | Size |
|---|---|---|---|---|
| 1.1 | **Stale-write guard** (in `bm_guard`) | Blocks writes to files changed since the worker read them (other agents or you) | 0.9 | S |
| 1.2 | **Repeat-call guard** | Stops loops like Fabric's recorded 220 identical GLM calls | 0.12 | S |
| 1.3 | **Approval inbox** in the browser | Real pi dialogs are answered by you instead of auto-declined | 0.13 | M |
| 1.4 | **Per-task diff view + revert button** | Review each task's change and undo it with one click | 0.10, 0.13 | M |
| 1.5 | **Small-request shortcut** | Single changes go straight to one worker; no planning overhead | 0.6 | S |
| 1.6 | **Worker self-check** (`bm_report`) | Rejects a worker with the wrong model, tools or versions before it works | 0.6 | S |
| 1.7 | **Run goal, budget and status in the UI** (active / blocked / budget-limited / complete) | See why a run stopped and what it cost | 0.4, 0.12 | S |
| 1.8 | **Command rules with alternatives** (Codex `execpolicy` style) | Blocks dangerous commands and tells the model what to do instead | 0.10 | M |
| 1.9 | **Pinned pi/Fabric versions for workers + upgrade check** | Updates can't silently break the bridge | 0.3 | S |
| 1.10 | **Record/replay tests** from `raw_log` | Test orchestration against real pi streams at no model cost | 0.1 | M |
| 1.11 | **Run history** (past runs, tasks, costs) | Answer "what did this run do and cost?" | 0.5 | M |

## P2: optional, medium priority

Build when usage shows the need.

| # | Feature | When it's worth it | Size |
|---|---|---|---|
| 2.1 | **Reviewer actor** (replies silent / message / stop) | When workers produce changes you'd otherwise review by hand | M |
| 2.2 | **`ask_planner` tool** for workers | When workers often stall on unclear tasks | S |
| 2.3 | **Front "questioning" agent** that sharpens the request before planning | When plans are often wrong because requests are vague | M |
| 2.4 | **Supervisor actor** (Foreman-style progress and drift checks) | When runs get long enough to go unattended | M |
| 2.5 | **CLI client** that attaches to runs | When you want to work from the terminal | M |
| 2.6 | **Fork workers from the planner's session** (Codex `fork_turns`) | If measurements show zro's caching makes it cheaper than short briefs | M |
| 2.7 | **Short labels** for runs and agents (`BM-12`) | As soon as there are many runs; tiny | S |
| 2.8 | **Transcript link per task** (pi `export_html`) | When you need a worker's full session | S |

## P3: optional, low priority / experimental

| # | Feature | Note | Size |
|---|---|---|---|
| 3.1 | **Council / fusion** for high-stakes plans | Costs 2–8× per plan; only for expensive-to-get-wrong work | M |
| 3.2 | **Learned memory** (extract + consolidate, as Oban jobs) | Needs many finished runs first | L |
| 3.3 | **Provider failover** (zro ↔ coralbricks for GLM) | Verify an extension can switch provider mid-turn first | M |
| 3.4 | **Interactive terminal sessions** for workers (type into `iex`, prompts) | Useful for Elixir; needs a PTY library | M |
| 3.5 | **Editor integration** via ACP | Only if you want to drive BM from an editor; not yet researched | M |
| 3.6 | **Slack notifications / control** | Only for use away from the computer | S |
| 3.7 | **Multiple machines** (BEAM distribution) | Only if one machine's RAM becomes the limit | L |

## Side track: pi extensions for personal use (independent of BM)

Useful in your own pi sessions; they don't block BM work.

| Feature | Source | Size |
|---|---|---|
| `/btw` side question in a throwaway fork | Codex | S |
| Learned memory for pi sessions | Codex | M |
| Command rules with alternatives | Codex | S–M |
| Stale-write guard | fx | S |
| Record and replay | fx | S–M |
| Stall-aware retry (contribution to pi-retry) | fx | S |
| `fork` option for Fabric sub-agents (contribution to Fabric) | Codex | M |
| Codex review rubric for pi-contour | Codex | S |

## Deliberately not planned

Git worktrees and merge queues; pure-Elixir LLM agents; re-implementing Fabric's in-agent features;
many tiny LLM agents. See [ARCHITECTURE.md § Non-goals](ARCHITECTURE.md#14-non-goals).
