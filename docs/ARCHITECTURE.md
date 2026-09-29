# BM architecture

Status: design, revised 2026-09-29. Milestone 1 experiment done (see [Verified facts](#11-verified-facts)).

BM is a multi-agent coding system. The **BEAM** (this Phoenix app) plans, dispatches, supervises and
limits the work and shows it in the browser. **pi** agents, driven over pi's RPC mode, do the coding,
with **pi-fabric** kept installed for its in-agent features. Workers share **one checkout**; there
are no git worktrees.

---

## 1. Goals and principles

**Goal:** turn one request into a plan, run its independent parts on several pi agents at once,
and deliver the combined result, with everything visible and controllable in the browser.

**Principles**

1. **Coordination by code, not by prompts.** The BEAM decides who works on what, when, and what
   happens on failure. Models only plan, code and report.
2. **Don't rebuild what pi or Fabric already do.** pi owns model calls, tools, sessions, retries and
   compaction. Fabric owns in-agent work (code mode, speculation, argument repairs, background jobs).
3. **One owner per job.** Fabric's own agent spawning is off in BEAM-managed processes; the BEAM is
   the only thing that starts, stops or assigns agents.
4. **Prevent conflicts early instead of resolving them late.** Files are claimed before they are
   edited; overlapping tasks are not run at the same time.
5. **Small, verifiable steps.** Every milestone works on its own and is checked against real pi.

---

## 2. Decisions

| # | Decision | Why | Rejected alternatives |
|---|---|---|---|
| D1 | BEAM orchestrates, pi codes | pi+Fabric already handle editing, GLM quirks, zro auth; the BEAM is best at supervision, messaging and state | Pure-Elixir "nano" agents (would rebuild edit tools, retries, arg repair, zro auth); Fabric as orchestrator (file-based mesh, invisible to the BEAM) |
| D2 | Keep Fabric installed and unmodified | In-agent features improve with every Fabric update; no fork to maintain; personal pi sessions unchanged | Stripping/forking Fabric |
| D3 | Fabric's orchestration is **not used** in BEAM-managed processes | Avoids two coordinators and hidden agents/cost | Letting workers spawn Fabric sub-agents |
| D4 | **No worktrees.** All workers share one checkout; the BEAM prevents conflicts with scheduling + file claims, and owns all git writes | Much simpler: no merge queue, no per-worker copies, no merge conflicts to resolve | Worktree per worker + merge queue (was in the earlier plan) |
| D5 | Planner runs **without** Fabric | Fabric's code mode hides extension tools from the model, which would hide `add_task` from the stream | Planner with Fabric |
| D6 | Streaming dispatch from `toolcall_delta` | GLM via zro uses pi's openai-completions path: every `toolcall_end` arrives only at the end of the message | Waiting for the whole plan |
| D7 | Worker → BEAM results via `bm:` notify records | Tool calls made inside `fabric_exec` emit no RPC events (Fabric's trace drops their arguments) | Reading results from tool events |
| D8 | Warm worker pool, reused with `new_session` | pi start costs 0.2–2 s and 134–405 MB; reuse avoids both | One process per task |
| D9 | Postgres for runs/tasks history, ETS for live claims and counters | Durable, queryable history; fast hot state | Files (Fabric's approach) |

Revisit a decision by adding a row, not by deleting one.

---

## 3. System overview

```
 Browser (LiveView + Svelte Flow)            CLI (later)
        │  PubSub item events ▲  commands          │
        ▼                     │                    ▼
┌──────────────────────────────── BEAM ─────────────────────────────────────┐
│  Bm.Runs ── Bm.Router ── Bm.Tasks (Postgres) ── Bm.Scheduler              │
│     │            ▲ tool_call_ready                 │ file-disjoint batches │
│     │            │                                 ▼                       │
│  Planner agent   │                     Bm.Workers.Pool (warm pi workers)   │
│  (Bm.Pi.Agent)───┘                        │   ▲                            │
│                                           │   │ bm: notify / bm: dialogs   │
│  Bm.Claims (ETS)  Bm.Git (only git writer)  Bm.Limits  Bm.Verifier  Actors │
└───────────┬───────────────────────────────┼───┼────────────────────────────┘
            │ RPC (JSONL over stdin/stdout)  │   │
            ▼                               ▼   │
   pi (planner): zro + bm_bridge      pi (worker ×N): zro + Fabric + bm_bridge
                                                  + bm_claims + bm_guard + bm_report
                                   all workers edit ONE shared checkout
```

---

## 4. Who does what

### BEAM (this app)

| Module | Status | Responsibility |
|---|---|---|
| `Bm.Pi.Agent` | **exists** | One pi process per agent through a Port; RPC commands; event reduction; env; raw log |
| `Bm.Pi.ToolCalls` | **exists** | Rebuilds tool calls from streamed deltas; reports each as soon as its JSON is complete |
| `Bm.Pi.Transcript` | **exists** | Chat transcript from agent events |
| `Bm.Runs` | new | One run per user request: goal, budget, status (active / blocked / budget-limited / complete / failed) |
| `Bm.Router` | new | Turns each streamed `add_task` into a task record immediately |
| `Bm.Tasks` | new | Task graph in Postgres: `depends_on`, declared `files`, status, attempts, result |
| `Bm.Scheduler` | new | Picks runnable tasks: dependencies met **and** declared files disjoint from running tasks |
| `Bm.Workers.Pool` | new | 2–6 warm workers (start with 2); `new_session` between tasks; stall watchdog |
| `Bm.Claims` | new | ETS table of exclusive write claims `file → task`; answers `bm_claims` dialogs |
| `Bm.Git` | new | The only process that runs git writes: per-task commits of claimed files, per-task revert |
| `Bm.Verifier` | new | After a batch settles: `mix compile --warnings-as-errors` + tests; failures go back to the planner |
| `Bm.Limits` | new | Run budget from pi's reported `usage.cost`, max workers, per-task timeout, repeat-call guard, stop-all |
| `Bm.Actors` | later | `gen_statem` watchers (reviewer, supervisor) fed by worker events; reply silent / message / stop |
| Item events (PubSub) | new | One event shape for UI/CLI: item started / delta / completed |
| Web UI | partial | Canvas of agents, task board, approval inbox, per-task diff and revert, budget |

### Our pi extensions (loaded with `-e` only in BEAM-managed processes)

| Extension | Status | Responsibility |
|---|---|---|
| `bm_bridge` | **exists** (`priv/pi/extensions/bm_bridge.ts`) | `add_task` (planner), `submit_result` (worker); reports through `bm:` notify |
| `bm_claims` | new | `tool_call` hook on `edit`/`write`: asks the BEAM for a write claim through a dialog; blocks the call when denied |
| `bm_guard` | new | Stale-write check (file changed since this session read it → block); command rules (no `git commit/checkout/reset/stash/push`, no destructive commands; suggest an alternative) |
| `bm_report` | new | On session start, reports model, active tools and versions so the BEAM can reject a misconfigured worker |

### Fabric (unchanged, inside each worker)

Code mode, speculative tool calls, argument repairs, background shell jobs, output limits, memory
search, MCP. Its agents/actors/mesh/worktrees are not used by BEAM-managed processes.

### pi core

Model calls, `read`/`edit`/`write`/`bash`, sessions, retries, steering and follow-up queues, compaction.

---

## 5. Communication channels (BEAM ⇄ pi)

| Direction | Mechanism | Used for |
|---|---|---|
| BEAM → pi | RPC commands: `prompt`, `steer`, `follow_up`, `abort`, `new_session`, `get_state`, `get_session_stats` | Assign, correct, stop, reuse, inspect |
| pi → BEAM | RPC session events (`message_update`, `tool_execution_*`, `agent_settled`, …) | Live state, streaming dispatch, UI |
| pi → BEAM, fire-and-forget | Extension notify: `{"method":"notify","message":"bm:{\"event\":…,\"data\":…}"}` | Task registered, result, file touched, self-report |
| pi → BEAM, **blocking** | Extension dialog (`confirm` / `input`) with a `bm:` title; the BEAM answers with `extension_ui_response` | Claims ("may I edit X?"), questions to the planner |

Rules:

- Dialogs whose title starts with `bm:` are answered by the BEAM automatically. Every other dialog
  goes to the **approval inbox** in the browser (today they are auto-declined).
- Every `bm:` payload is JSON: `{"event": string, "data": object}`.

---

## 6. Process profiles

| Role | Command | Memory (measured) |
|---|---|---|
| Planner | `pi --mode rpc --no-session --no-extensions -e <zro> -e bm_bridge --model zro/glm-5.3` | ~134 MB |
| Worker | `pi --mode rpc --no-session --no-extensions -e <zro> -e <fabric> -e bm_bridge -e bm_claims -e bm_guard -e bm_report --model zro/glm-5.3` | ~260 MB (+ small extensions) |
| Reviewer (later) | like the planner, read-only tools | ~134 MB |

All BEAM-managed processes get `PI_FABRIC_DEPTH=99` (Fabric refuses to spawn children when the
current depth ≥ `agents.maxDepth`). Pin the Fabric and pi versions used by workers; after any upgrade,
rerun the experiment script before trusting the system again.

---

## 7. Run lifecycle

1. **Request.** The user sends a request; `Bm.Runs` creates a run with a goal and budget.
2. **Small or large?** Small requests (a single change) go straight to one worker. Large ones go to
   the planner.
3. **Plan.** The planner registers tasks with `add_task(id, title, goal, files, depends_on, done_when)`.
   `Bm.Pi.ToolCalls` reports each call as soon as its arguments are complete; `Bm.Router` stores it.
4. **Schedule.** `Bm.Scheduler` starts every task whose dependencies are done and whose declared
   files don't overlap a running task. Overlapping tasks wait.
5. **Work.** A worker gets the task brief (goal, files, done_when, short project context). Before each
   `edit`/`write`, `bm_claims` asks the BEAM for the file. The worker finishes with `submit_result`.
6. **Commit.** `Bm.Git` commits exactly the files claimed by that task (`git add <files>`,
   `git commit -m "<task id>: <title>"`) and releases the claims.
7. **Verify.** When no task is mid-edit (a batch has settled), `Bm.Verifier` compiles and runs tests.
   On failure, the output goes to the planner as a follow-up; it can add fix tasks.
8. **Report.** Results reach the planner as `follow_up` messages, never by polling. The run ends
   when all tasks are done and verification passes, or when a limit or the user stops it.

---

## 8. Shared checkout: concurrency model

Without worktrees, all workers see each other's changes as they happen. The rules below keep that safe.

| Rule | Where enforced |
|---|---|
| Tasks declare the files they will touch; tasks with overlapping files never run at the same time | `Bm.Scheduler` |
| Before writing a file, a worker must hold its claim; a claim is exclusive to one task | `bm_claims` + `Bm.Claims` |
| Writing a file not declared by the task is allowed only if no other task holds or declared it; the BEAM records it | `Bm.Claims` |
| A file changed since the worker read it cannot be written (another agent or the user changed it) | `bm_guard` stale-write check |
| Workers never run git commands that change state; only `Bm.Git` does | `bm_guard` command rules |
| Workers run only focused checks (compile, tests for their files); the full suite runs in `Bm.Verifier` after a batch | worker brief + `Bm.Verifier` |
| A failed or aborted task is reverted by restoring only its claimed files | `Bm.Git` |

Conflict cases:

| Situation | Outcome |
|---|---|
| Worker B wants a file claimed by task A | Edit blocked; B is told who owns it. B continues other work or reports `blocked`; the BEAM reschedules B after A |
| Worker's compile fails because of another worker's half-finished edit | Worker is told to check only its own files; the Verifier catches real breakage after the batch |
| The user edits a file during a run | Stale-write guard blocks the worker's next write to that file; UI shows it. Recommended: pause the run before editing by hand |
| Two tasks were declared disjoint but need the same undeclared file | The first claim wins; the second is blocked and rescheduled |

Known costs of this model: less parallelism when tasks share files, and workers can observe each
other's intermediate states. Both are accepted in exchange for having no merge step.

---

## 9. Data model

Postgres (Ecto):

- `runs`: id, goal, status, budget_usd, spent_usd, started_at, finished_at
- `tasks`: id, run_id, key (planner id), title, goal, files[], depends_on[], done_when, status
  (queued / running / done / blocked / failed / reverted), attempts, worker, result (json), commit_sha
- `items`: run_id, task_id, agent, kind, status, payload (json), inserted_at (the event log)

ETS:

- `claims`: file → {task_id, worker}
- `limits`: run_id → counters (spent, tool calls, repeated-call streaks)

---

## 10. Limits and safety

- Run budget from pi's reported `usage.cost`; stop dispatching at the limit, abort at a hard limit.
- Worker pool size capped by RAM (16 GB machine: 4–6 workers; start with 2).
- Per-task timeout; stall watchdog (no events for N seconds → abort, then kill the process).
- Repeat-call guard: the same tool call with the same arguments K times in a row → abort the task
  (Fabric recorded a GLM case of 220 identical calls).
- One stop button for everything.
- Command rules in `bm_guard`; approvals for non-`bm:` dialogs in the browser inbox.

---

## 11. Verified facts

Measured on 2026-09-29 against pi 0.87.1, Fabric 0.97.0, GLM 5.3 via zro, 16 GB / 10-core Mac.

| Fact | Evidence |
|---|---|
| pi RPC process memory: full setup 405 MB, zro+Fabric 259 MB, zro only 134 MB | `ps` RSS of idle processes |
| Startup to first `get_state` response: full setup ~2.1 s, planner profile 0.2 s, worker profile 0.8 s | experiment timings |
| Streaming dispatch works: 6 `add_task` calls ready at 2.4 / 3.8 / 5.0 / 6.2 / 7.5 / 8.5 s; message ended ≈ 8.5 s | experiment A |
| zro GLM runs on pi's `openai-completions` API (all `toolcall_end` at the end) | raw RPC log; `packages/ai/src/api/openai-completions.ts:680` |
| zro reports prompt-cache reads (`cache_read` ≈ 10k tokens) although pi's model metadata says no cache | experiment A usage |
| Extension tools called inside `fabric_exec` emit no RPC events; Fabric's trace has `args: {}` | experiment B |
| `bm:` notify from inside `fabric_exec` reaches the BEAM | experiment B2 |
| `new_session` resets a warm process | experiment C |
| The user's Fabric config has `agents.maxDepth: 0`; `PI_FABRIC_DEPTH` ≥ maxDepth also blocks spawning | error text + `agents/manager.ts` |
| pi `tool_call` hooks can block a call; `confirm` dialogs return `confirmed: true/false` | pi `docs/extensions.md`, `docs/rpc-extension-ui.md` |

Experiment scripts live outside the repo; recreate them from this table if needed. The agent's
`raw_log` option records real RPC streams for replay tests.

---

## 12. Open questions (verify before relying on them)

1. Can a `tool_call` hook in `bm_claims` await a dialog, and does it fire for `pi.edit` calls made
   inside `fabric_exec`? (Fabric's docs say it replays pi's tool lifecycle for nested calls.)
2. Dialog round-trip latency per edit: acceptable, or should claims be granted per task up front?
3. How well does GLM 5.3 declare `files` in `add_task`? Scheduling quality depends on it.
4. Does the stale-write guard see edits made through Fabric's code mode?
5. Do workers obey "no git writes" and "focused checks only", or does `bm_guard` block them often?
6. Real cost and time per run versus a single pi agent on the same task (the go/no-go metric).
7. Is forking workers from the planner's session worth it now that zro caches? Measure later.
8. Which Fabric settings in the user's `fabric.json` (approvals, `prewalk.alwaysRearm`, mesh) affect workers?

---

## 13. Milestones

The full prioritized list is in [FEATURES.md](FEATURES.md); milestones group its items.

| # | Scope (FEATURES.md items) | Done when |
|---|---|---|
| M1 | P0 0.4–0.7, 0.12, 0.13: runs, router, tasks, pool of 2 workers, results as follow-ups, basic limits, canvas | A real request is planned, run on 2 workers and summarized within budget, with every task visible |
| M2 | P0 0.8–0.11: scheduler file rules, `bm_claims`, `Bm.Git` per-task commits and revert, `Bm.Verifier` | Parallel tasks on one checkout never write the same file; a failed task is reverted cleanly |
| M3 | P1: guards, approval inbox, diff view, small-request shortcut, self-check, run status UI, command rules, pinned versions, replay tests, history | Safe to leave running on a real repository |
| M4 | P2/P3 items, only where M1–M3 usage shows the need | Driven by real use |

Already done: `Bm.Pi.Agent` with env/raw log/`new_session`, `Bm.Pi.ToolCalls`, `bm_bridge`, the
experiment (24 tests pass).

---

## 14. Non-goals

- Git worktrees and merge queues.
- Re-implementing Fabric's in-agent features or pi's tools in Elixir.
- Pure-Elixir LLM agents.
- Many tiny LLM agents; parallelism is bounded by RAM, provider limits and budget.
- Cross-machine distribution (possible later with BEAM distribution; not designed yet).

---

## 15. Code map

| Path | What |
|---|---|
| `lib/bm/pi.ex` | Public API: `ensure_agent`, `prompt`, `new_session`, `abort`, `snapshot`, `subscribe`, `stop` |
| `lib/bm/pi/agent.ex` | RPC agent process |
| `lib/bm/pi/tool_calls.ex` | Streamed tool-call assembler |
| `lib/bm/pi/transcript.ex` | Transcript reducer |
| `priv/pi/extensions/bm_bridge.ts` | `add_task`, `submit_result` |
| `lib/bm_web/live/home_live.ex` | Chat + canvas page |
| `assets/svelte/` | Svelte Flow canvas and agent node |
| `test/support/fake_pi.mjs` | Scripted pi stand-in for tests |
| `config/config.exs` | `Bm.Pi` command and cwd |

## 16. References

- pi RPC: `docs/rpc.md`, `docs/rpc-commands.md`, `docs/json.md`, `docs/rpc-extension-ui.md`, `docs/extensions.md` in the pi package.
- pi-fabric (MIT): agents/actors/mesh docs, `docs/entropy.md`, `docs/speculation.md`.
- Codex (Apache-2.0): multi-agent v2 tools, thread/turn/item protocol, `execpolicy`, memory pipeline.
- fx (Apache-2.0): stale-read tracking, parallel read-only prefix, child permission ceiling.
- pi durable runtime spec (Pico5): tasks as durable state machines, the "effect sandwich".
