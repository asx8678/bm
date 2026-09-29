# BM architecture

Revised 2026-09-29 (second revision, after an external design review).
The prioritized roadmap is in [FEATURES.md](FEATURES.md).

BM is a multi-agent coding system. The **BEAM** (this Phoenix app) plans, authorizes, schedules,
supervises, verifies and records work, and shows it in the browser. **pi** agents, driven over pi's
RPC mode, do the coding. **pi-fabric** stays installed, unmodified, for its in-agent features.
All agents share **one checkout**; there are no git worktrees.

> **Core rule:** the planner *proposes* work; the BEAM *authorizes* effects; workers *report*
> outcomes; *verification* decides acceptance.

This document separates three kinds of statements. **Implemented** means code and tests exist.
**Designed** means decided but not built. **Assumption** means it must still be qualified against
real pi/Fabric before anything relies on it.

---

## 1. Principles

1. **Coordination by code, not by prompts.** Models plan, code and report. The BEAM decides.
2. **Don't rebuild pi or Fabric.** pi owns model calls, tools, sessions, retries and compaction.
   Fabric owns in-agent features (code mode, speculation, argument repairs).
3. **One authority for agents.** Only the BEAM starts, assigns and stops agents. No hidden
   recursive orchestration.
4. **Conservative before parallel.** V1 allows parallel *read-only* work and exactly **one mutating
   worker at a time**. More mutating workers come only after their safety tests pass.
5. **Never touch the user's git state.** BM never moves your branch, never changes your index or
   staged changes, never stashes, and never overwrites a file it didn't change.
6. **Honest guarantees.** Each guarantee states what enforces it (section 8). Blocklists and prompts
   are not sandboxes.
7. **Smallest reliable slice first.** Every stage works on its own and is measured.

---

## 2. Decisions

| # | Decision | Why | Rejected |
|---|---|---|---|
| D1 | BEAM orchestrates; pi codes | pi+Fabric handle editing, GLM quirks and zro auth; the BEAM is best at supervision, state and messaging | Pure-Elixir LLM agents; Fabric as the orchestrator |
| D2 | Fabric installed and unmodified; BM agents use **controlled profiles** (Fabric-free for now, D16) | In-agent features improve with Fabric updates; no fork | Forking Fabric; managed-host mode for now (see D14) |
| D3 | Shared checkout, **no worktrees**, no merge queue | Much simpler; conflicts are prevented by scheduling instead of merged | Worktree per worker |
| D4 | **One active run per workspace** (V1) | Removes cross-run conflicts entirely | Cross-run admission logic |
| D5 | **One mutation lane**: at most one mutating attempt at a time; read-only attempts run in parallel | Shell commands, formatters and generators can change files without any hook seeing it; serializing mutations makes attribution exact | Parallel writers guarded only by edit/write hooks |
| D6 | Streaming produces **proposals**; only **accepted** tasks may mutate | Parseable partial output is not an authorization | Dispatching directly from `toolcall_delta` |
| D7 | Authoritative operations use **dialogs** (pi waits for the BEAM's answer); telemetry uses notify | Gives request/response with durable acknowledgment over the existing channel | Fire-and-forget notify for everything |
| D8 | Identity comes from the **channel** (the agent's own Port) plus the BEAM's active assignment, never from model-supplied ids | Models can't forge which process they are | Trusting ids in tool arguments |
| D9 | **Separate planner and worker extensions** | Role-specific capabilities: planners propose, workers report only their own attempt | One extension registering all tools |
| D10 | **Fresh pi process per attempt** in V1 | Start-up is 0.2–0.8 s with lean profiles; no reset qualification needed | Warm pool (optional later) |
| D11 | Workspace **snapshots before and after** each mutating attempt give its actual write set | Attributes every mutation path (tools, shell, formatters), which hooks alone can't | Hook-only attribution |
| D12 | Checkpoints are **private git commits under `refs/bm/…`**, built with a separate index | Records exactly what was verified without touching HEAD, the branch or the user's index | `git add <files> && git commit` (would include the user's staged changes) |
| D13 | Postgres is authoritative; ETS holds live projections only | Recovery after a crash needs durable state | ETS-only claims and state |
| D14 | Fabric's **managed-host mode** is noted, not used | It gives a clean provider boundary, but disables speculation, prewalk, repairs, entropy and native MCP, and requires the host to broker pi's core tools | Adopting it now |
| D16 | **Workers are Fabric-free** (decided 2026-09-29): planner, reader and writer run plain pi with zro and BM extensions | Live A6 showed `--tools` doesn't bind Fabric's nested calls and Fabric starts the user's MCP servers; without Fabric, `--tools` and `bm_guard` fully cover the worker's tools | A BM-managed `PI_CODING_AGENT_DIR` with its own `fabric.json` (optional later; needs access to the user's pi credentials); guard-only control with the user's Fabric config |
| D15 | Planner runs **without** Fabric | Simplicity: the planner writes no code. (Fabric hides extension tools by default, but `capture.keepVisible` could keep them visible, so this is a choice, not a necessity) | Planner with Fabric |

Revisit a decision by adding a row, not by deleting one.

---

## 3. Structure

```
 Browser (LiveView + Svelte Flow)                     CLI (optional, later)
        │ item events ▲  commands
        ▼             │
┌──────────────────────────────────── BEAM ─────────────────────────────────────┐
│  Run coordinator (one per run)                                                  │
│    goal · budget · accepted plan waves · task graph · planner inbox             │
│        │ admits attempts                     ▲ results, events                  │
│        ▼                                     │                                  │
│  Workspace coordinator (one per checkout)                                       │
│    run lock · mutation lane · baseline & dirty-file policy · snapshots          │
│    attempt journal · verification barrier · checkpoints (refs/bm/…)            │
│        │ starts / stops                                                         │
│        ▼                                                                        │
│  Agent adapter: Bm.Pi.Agent (one process per pi process)                        │
│    Port · RPC · dialogs · session epoch · health · process-tree kill            │
│                                                                                 │
│  Limits (budget, timeouts, repeat guard) · Postgres (authoritative) · ETS       │
└──────┬───────────────────────────────┬─────────────────────────┬────────────────┘
       │ RPC                           │ RPC                     │ RPC
  pi planner                    pi read-only worker(s)      pi mutating worker (≤1)
  zro + bm_planner              zro + Fabric + bm_worker    zro + Fabric + bm_worker
                                no edit/write/bash tools    + bm_guard
                        all share ONE checkout
```

Process boundaries follow state ownership: a run coordinator per run, one workspace coordinator
per checkout, one adapter process per pi process. Other pieces (scheduler, validator, git helpers)
are plain modules called by their owner, not separate processes.

---

## 4. Roles and profiles

| Role | Extensions | Tools | Memory |
|---|---|---|---|
| Planner | zro, `bm_planner` | read-only pi tools + `propose_task`, `close_plan` | ~134 MB |
| Read-only worker | zro, `bm_worker` | `read`, `grep`, `find`, `ls`, `submit_result` | ~134 MB |
| Mutating worker | zro, `bm_worker`, `bm_guard` | read tools, `edit`, `write`, policed `bash`, `submit_result` | ~134 MB |
| Reviewer (optional) | zro, `bm_worker` | read-only + `submit_result` | ~134 MB |

Every agent is started with `--no-extensions` and an explicit `-e` list, and pinned model.
**Profile check before assignment:** `bm_worker`/`bm_planner` report the effective model, active
tools and versions on start; the adapter compares them with `get_state`. A mismatch fails closed
(the agent is stopped and the attempt is not started). Fabric's own agent spawning must be off
through configuration (`agents.maxDepth: 0` today); `PI_FABRIC_DEPTH` is only an extra guard, since
it is an internal Fabric variable.

---

## 5. Channels between BEAM and pi

| Direction | Mechanism | Used for | Reliability |
|---|---|---|---|
| BEAM → pi | RPC commands (`prompt`, `follow_up`, `abort`, `get_state`, `get_session_stats`) | Assign, deliver results, stop, inspect | pi responds with `success`; the adapter waits for it |
| pi → BEAM | RPC session events | Live state, streamed proposals, UI | Best effort (telemetry) |
| pi → BEAM | Extension **notify** `bm:{…}` | Progress hints, self-report | Best effort (telemetry) |
| pi → BEAM → pi | Extension **dialog** with a `bm:` title; the BEAM answers with `extension_ui_response` | `propose_task`, `close_plan`, `submit_result`, permission questions | **Authoritative**: the BEAM persists, then answers; the tool returns the BEAM's answer |

Dialog payload (JSON in the dialog message):

```json
{"v": 1, "op": "submit_result", "request_id": "<uuid from the extension>", "payload": {...}}
```

The BEAM adds the identity: which agent (from the Port), which run, task and attempt (from its
active assignment), and the session epoch. Duplicate `request_id`s return the stored outcome.
Dialogs with any other title go to the approval inbox (optional feature) or are declined.

---

## 6. Runs, plans and tasks

**Plan progression.** A streamed `propose_task` call can populate the UI and trigger bounded
read-only preparation. It becomes executable only through:

```
proposed ──▶ validated ──▶ accepted ──▶ scheduled
```

- *Validated*: schema, stable key, dependencies exist, no cycles, declared write set present for
  mutating tasks, budget admits it, current planner generation.
- *Accepted*: the BEAM persisted it and answered the planner's dialog. Accepted task definitions are
  immutable; changes are new revisions.
- Streamed arguments are reconciled with the final call; cancelled, malformed or superseded
  proposals never become executable.
- Plans arrive in **waves**. A run can't complete while planning is open: the planner calls
  `close_plan`, or the run times out waiting for it.

**Task vs attempt.** A task is the logical unit; an attempt is one execution of it.

```
queued ─▶ admitted ─▶ running ─▶ result_received ─▶ settling ─▶ verifying ─▶ accepted
                 ╰──────────▶ blocked | failed | cancelled | needs_reconciliation
```

Only the BEAM moves an attempt to `accepted`. A worker's `submit_result` means "I think I'm done";
it doesn't mean its tools stopped, files are stable or verification passed. Dependents consume
**accepted** results.

**Fencing.** Each attempt has an id and each agent adapter a session epoch. Messages carrying an
old attempt or epoch are rejected. Fencing does not stop an OS process, so before a retry or
reassignment the old process tree must be terminated or proven settled.

**Results to the planner.** Receive → persist → settle and verify → queue → deliver as a
`follow_up` at the planner's next boundary, batching related results. Routine results never
interrupt the planner. The BEAM records *received*, *delivered* and *acknowledged* separately.
Cancellation and safety events use a separate, prioritized path (`abort`).

---

## 7. Workspace coordinator

**Baseline and dirty policy.** At run start the coordinator records HEAD and the content hash of
every modified, staged or untracked (non-ignored) file. Those files are **user-owned** for the run:
agents may read them; a task that needs to change one is blocked and reported. BM never stages,
stashes or commits user changes.

**Mutation lane.** At most one mutating attempt runs at a time (D5). Read-only attempts run in
parallel up to a small limit.

**Attribution by snapshot (D11).** Before a mutating attempt starts and after it settles, the
coordinator snapshots the workspace (content hashes of tracked and untracked non-ignored files).
The difference is the attempt's **actual write set**, whatever tool or command produced it. It is
compared with the **declared** write set; writes outside it are flagged for review, and writes to
user-owned files fail the attempt.

**Settling.** An attempt is settled when pi reports `agent_settled`, no tool is running, and the
pi process has **no descendant processes**. V1 disallows detached background work in workers.

**Verification barrier.** With the mutation lane empty, the coordinator runs verification
(`mix compile --warnings-as-errors` and the relevant tests), then records a **checkpoint**: a
commit object built from the working tree with a *separate* git index and stored under
`refs/bm/runs/<run>/<n>`. HEAD, the branch and the user's index are untouched. The checkpoint id is
the exact state that was verified.

**Rollback (V1).** Restore an attempt's attributed files from the previous checkpoint, only if
their current content still equals what the attempt produced; created files are removed and deleted
files restored under the same check. Any newer or external change stops the rollback and asks the
user. Dependent accepted tasks block rollback of the task they depend on.

**Freshness (from fx).** `bm_guard` records the content hash of every file the worker reads
(whole-file freshness tracked separately from whether the model saw the whole file) and blocks
`edit`/`write` when the file changed since, checking and writing as one step. New files, deletes,
renames and symlinks resolve to canonical paths.

---

## 8. Guarantees (V1) and their enforcement

| Guarantee | Enforced by | Not guaranteed |
|---|---|---|
| No two BM workers change files at the same time | Mutation lane (D5) | — |
| Read-only workers can't change files through pi tools | Tool allowlist per profile | MCP tools or extensions outside the profile (profiles exclude them) |
| Every change a mutating attempt makes is attributed to it | Before/after snapshots | Changes the *user* makes during that attempt are also attributed to it; the UI warns, and freshness checks catch edits to files the worker read |
| User changes are never committed, stashed or overwritten by BM | Baseline policy, private-index checkpoints, conditional rollback | A shell command inside a mutating attempt could still overwrite a user-owned file; it is detected (snapshot) and the attempt fails, but the overwrite already happened |
| Accepted means verified | Verification barrier + checkpoint id | Test coverage decides what "verified" catches |
| Stale messages can't affect a new attempt | Attempt ids + session epoch | — |
| Spending stays near the budget | Admission stops at the limit; hard limit aborts | Requests already in flight can exceed it; missing cost is "unknown", never 0 |

Command policy in `bm_guard` blocks known-dangerous commands (git writes, `rm -rf` outside the
checkout, publishing) and suggests alternatives. It is a safety net, not a sandbox.

---

## 9. Data model

Postgres (authoritative):

- `workspaces`: canonical path, active_run_id (the run lock)
- `runs`: goal, status, plan_open, budget, spent_confirmed, spent_unknown, baseline (json)
- `tasks`: run, key, revision, definition (json), declared_writes, depends_on, status
- `attempts`: task, number, role, agent, session_epoch, status, snapshot_before/after, actual_writes, result, checkpoint
- `requests`: request_id, agent, op, payload, outcome (idempotency for dialogs)
- `deliveries`: target, message, received_at, delivered_at, acknowledged_at
- `checkpoints`: run, number, git ref, verified (json)
- `items`: ordered event log for UI and recovery (run/task/attempt/item ids, sequence)

ETS (projections): live agent status, lane occupancy, counters.

---

## 10. Limits and observability

- Budget: confirmed spend from pi's `usage.cost`; entries without cost are marked unknown.
  Admission stops at the soft limit; the hard limit aborts running attempts.
- Timeouts that distinguish provider wait, running tool, approval wait and true stall, instead of
  one "no events" timeout.
- Repeat-call guard (same call and arguments K times in a row → abort).
- Bounded buffers: RPC line buffer, pending requests, transcripts, logs, event queues.
- Raw RPC logs are sensitive (prompts, paths, file contents); replay fixtures are sanitized.

---

## 11. Recovery

After a BEAM restart or an uncertain failure: freeze admission for the workspace, stop or confirm
the state of every recorded pi process, compare the workspace with the last snapshot and
checkpoint, then decide per attempt: resume, retry (only if it provably changed nothing), revert
(if the conditional rollback applies) or mark `needs_reconciliation` for the user. An attempt that
may have changed files is never retried automatically.

---

## 12. Status

**Implemented** (tests use a scripted fake pi; live runs as noted):

- `Bm.Pi.Agent`: Port, RPC events, transcript, extra env, raw log, `new_session`, abort. Known gaps
  fixed in stage A: `new_session` replies before pi confirms; usage drops cost and turns missing
  values into 0; unbounded buffers and transcript.
- `Bm.Pi.ToolCalls`: assembles streamed tool calls. Gap: reports calls as ready before any
  validation (to become "proposed").
- `bm_bridge`: `add_task` and `submit_result` in one extension, fire-and-forget. To be replaced by
  role-specific `bm_planner` / `bm_worker` with dialogs.
- Chat page and canvas with one agent node.

**Designed, not implemented:** everything in sections 5–11 not listed above.

**Stage A progress:** A1–A6 implemented (acknowledged commands, cost, bounds, proposals,
authoritative dialogs with persisted idempotent requests, split extensions, Fabric-free profiles
with a fail-closed check, graceful shutdown, `bm_guard`). Live qualification: 4/4 pass
(`mix test --only live`). A7: live tests are in `test/live/`; recorded fixtures are not committed
until an allowlist sanitizer exists (raw streams contain the local pi environment).

---

## 13. Verified facts

Measured 2026-09-29: pi 0.87.1, Fabric 0.97.0 (source read at 0.98.1), GLM 5.3 via zro, 16 GB Mac.

| Fact | Evidence |
|---|---|
| pi RPC memory: full setup 405 MB, zro+Fabric 259 MB, zro only 134 MB | `ps` RSS |
| Start-up to first response: full 2.1 s, planner profile 0.2 s, worker profile 0.8 s | experiment |
| zro GLM runs on pi's `openai-completions` API; all `toolcall_end` arrive at the end | raw log; `openai-completions.ts:680` |
| 6 streamed `add_task` calls complete at 2.4–8.5 s; message ended ≈ 8.5 s | experiment A |
| zro reports prompt-cache reads (~10k tokens) despite pi's metadata | experiment A |
| Extension tools called inside `fabric_exec` emit no RPC events; Fabric's trace has `args: {}` | experiment B |
| A notify sent from inside `fabric_exec` reaches the BEAM | experiment B2 |
| `new_session` over RPC succeeds on a warm process | experiment C |
| User's Fabric config has `agents.maxDepth: 0` | Fabric error text |
| pi `tool_call` hooks can block; `confirm` dialogs return `confirmed`; `input` returns text | pi docs |
| Fabric hides extension tools by default; `capture.keepVisible` can keep them visible | Fabric `docs/configuration.md` |
| Fabric managed-host v1 disables speculation, prewalk, repairs, entropy and native MCP | Fabric `docs/providers.md` |
| Running Fabric in the checkout writes `.pi/fabric/` (mesh state, MCP cache) even with agents off | observed; now in `.gitignore` |
| **`--tools` does not restrict Fabric's nested calls**: a "read-only" worker (no `write` in `--tools`) created a file with `pi.write` inside `fabric_exec` | live qualification A6 |
| With Fabric loaded, the only active tool is `fabric_exec`; extension tools such as `submit_result` are captured and reachable as `extensions.<tool>` | live A6 (profile self-report) |
| `bm:` dialogs from inside `fabric_exec` reach the BEAM and return its answer | live A6 |
| `bm_guard`'s `tool_call` hook fires for nested `pi.write`, awaits the BEAM, and a denied write creates nothing | live A6 |
| The guard sees background shell requests (`{"background": true, ...}`); such a process outlives `agent_settled` as a pi descendant | live A6 |
| A `ChatGPT.app … node_repl` process ran as a descendant of a Fabric worker's pi, most likely an MCP server started by Fabric from the user's config (not confirmed) | live A6, `ps` |
| pi's auth-storage lock goes stale after 30 s (`proper-lockfile`, `stale: 30_000`); killing pi can delay the next start by ~30 s. Graceful exit via the `/bm-shutdown` extension command stops pi in 8–13 ms with fast restarts (0.82 s) | measured; pi `auth-storage.ts` |
| `PI_CODING_AGENT_DIR` sets the config directory for both pi and Fabric | Fabric `core/agent-dir.ts` |
| A checkpoint built with a separate index (`GIT_INDEX_FILE` + `read-tree HEAD` + `add -A` + `commit-tree` + `update-ref refs/bm/…`) leaves HEAD, the branch and the user's staged changes untouched and records the full working tree | throwaway-repo test with a staged and an untracked user file |

---

## 14. Open questions

Answered in stage A6 (live, 2026-09-29):

1. Dialogs from inside `fabric_exec` reach the BEAM: **yes**.
2. `bm_guard` awaits the BEAM and fires for nested `pi.write`; a denial writes nothing: **yes**.
3. Missing guard: the writer profile requires the guard's self-report, so a worker without it is
   rejected before assignment (profile check). A guard that loads but can't reach the BEAM blocks.
4. `--tools` restricts Fabric's nested calls: **no**. Resolved by D16: workers are Fabric-free.
   Re-qualified live with Fabric-free profiles: the reader has only read tools plus
   `submit_result` and can't create files; the writer's every `write` goes through `bm_guard`
   and a denied write creates nothing.
5. Background processes: the guard sees each bash command. A `nohup … &` command is re-parented
   to PID 1 after the shell exits, so it **escapes pi's process tree** and a descendant check
   can't see it (reproduced live). Settling (stage B5) must track the worker's **process group**
   (start pi as a group leader, check and kill by group) and the command policy should refuse
   detaching patterns (`nohup`, trailing `&`, `disown`, `setsid`). Neither is a sandbox: a
   process that creates its own session still escapes.

Still open:
6. Which settings in the user's `fabric.json` (approvals, `prewalk.alwaysRearm`, mesh, MCP) affect
   workers, and can the profile check see them?
7. How well does GLM 5.3 declare write sets? (Affects scheduling in stage D.)
8. Cost, time and success versus a single pi on the same tasks (the benchmark in stage C).

---

## 15. Non-goals

Git worktrees and merge queues; pure-Elixir LLM agents; re-implementing Fabric's in-agent features
or pi's tools; many tiny LLM agents; distributed execution, councils, learned memory and extra
supervisor agents before the basic system is reliable.

---

## 16. Code map

| Path | What |
|---|---|
| `lib/bm/pi.ex` | Public API for agents |
| `lib/bm/pi/agent.ex` | Agent adapter (RPC process) |
| `lib/bm/pi/tool_calls.ex` | Streamed tool-call assembler |
| `lib/bm/pi/transcript.ex` | Transcript reducer |
| `priv/pi/extensions/bm_bridge.ts` | Current bridge (to be split into `bm_planner` / `bm_worker`) |
| `lib/bm_web/live/home_live.ex`, `assets/svelte/` | Chat page and canvas |
| `test/support/fake_pi.mjs` | Scripted pi stand-in |

References: pi RPC and extension docs; pi-fabric (MIT); Codex (Apache-2.0) multi-agent tools,
item protocol, `execpolicy`; fx (Apache-2.0) read tracking and parallel read-only prefix; pi's
durable runtime spec (Pico5).

---

## Appendix A: design review (2026-09-29)

An external review ("architecture hardening and implementation brief") was checked against the code
and the Fabric source before this revision. Its core rule was adopted (see the top of this document).

**Findings verified in the code (all confirmed):**

| Finding | Location | Stage |
|---|---|---|
| Streamed calls become actionable as soon as their JSON parses, before validation | `lib/bm/pi/tool_calls.ex` (`JSON.decode(call.buffer)`) | A4 |
| The bridge answers "queued"/"recorded" without a BEAM acknowledgment | `priv/pi/extensions/bm_bridge.ts` (`report(...)` then `return`) | A3 |
| Planner and worker tools are registered in one extension | `bm_bridge.ts` (`registerTool` ×2) | A2 |
| `new_session` replies `:ok` before pi confirms | `lib/bm/pi/agent.ex` (`handle_call(:new_session, …)`) | A1 |
| Usage summaries drop `cost` and turn missing values into 0 | `agent.ex` (`usage_summary/1`); pi sends `usage.cost.total` | A1 |
| Line buffer, transcript and raw log are unbounded | `agent.ex` | A1 |
| `git add <files> && git commit` would include the user's staged changes | design (old §7) | replaced by D12 |
| edit/write hooks miss shell, formatter, generator, MCP and background mutations | design (old §8) | replaced by D5 + D11 |

**Findings verified in Fabric:** `capture.keepVisible` can keep extension tools visible (D15 corrected);
managed-host v1 exists and disables speculation, prewalk, repairs, entropy and native MCP (D14);
`PI_FABRIC_DEPTH` is an internal variable, so configuration plus a profile check is the real guard.

**Adopted as proposed:** proposed → validated → accepted; task vs attempt with fencing; settle before
verify; verification barrier bound to a recorded state; non-interrupting result delivery with
received/delivered/acknowledged; conditional rollback; honest guarantees; missing cost is unknown;
bounded buffers; sanitized replay fixtures; staged roadmap with exit gates; benchmark against a
single pi.

**Simplified for a single-user V1:**

| Review proposal | V1 equivalent |
|---|---|
| Cross-run admission in a workspace coordinator | One active run per workspace (lock) |
| General versioned envelopes with session epochs | `bm:` dialogs with `v`, `op`, `request_id`; identity from the Port; attempt id + session epoch added by the BEAM |
| Estimated in-flight spend, reservations, pricing confidence | Confirmed spend + unknown; estimates optional |
| Per-task undo with dependency semantics | Verified checkpoints + conditional rollback of one attempt |
| Warm pool as part of the core | Fresh process per attempt; warm reuse optional |
| Claims as the V1 conflict mechanism | One mutation lane + snapshots; claims move to the optional "two mutating workers" feature |
