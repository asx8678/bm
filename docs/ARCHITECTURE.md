# BM architecture

Revised 2026-09-29 (third revision: Phase 0 of the implementation plan).
The prioritized roadmap is in [FEATURES.md](FEATURES.md); the step-by-step plan for the core is in
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

BM is a multi-agent coding system. The **BEAM** (this Phoenix app) plans, authorizes, schedules,
supervises, verifies and records work, and shows it in the browser. **pi** agents, driven over pi's
RPC mode, do the coding. BM agents run **plain pi** (zro plus BM's own extensions); pi-fabric stays
installed and unmodified for the user's own pi sessions, and BM does not load it (D16).
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
   Fabric's in-agent features (code mode, speculation, argument repairs) are not re-implemented;
   BM workers go without them until Fabric can be re-added under BM's control (D16).
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
| D1 | BEAM orchestrates; pi codes | pi handles editing, GLM quirks and zro auth; the BEAM is best at supervision, state and messaging | Pure-Elixir LLM agents; Fabric as the orchestrator |
| D2 | Fabric stays unmodified (no fork); BM agents use **controlled profiles**, currently Fabric-free (D16) | If Fabric is re-added, its in-agent features improve with Fabric updates | Forking Fabric; managed-host mode for now (see D14) |
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
| D15 | Planner runs **without** Fabric | Simplicity: the planner writes no code. (Fabric hides extension tools by default, but `capture.keepVisible` could keep them visible, so this is a choice, not a necessity) | Planner with Fabric |
| D16 | **Workers are Fabric-free** (decided 2026-09-29): planner, reader and writer run plain pi with zro and BM extensions | Live A6 showed `--tools` doesn't bind Fabric's nested calls and Fabric starts the user's MCP servers; without Fabric, `--tools` and `bm_guard` fully cover the worker's tools | A BM-managed `PI_CODING_AGENT_DIR` with its own `fabric.json` (optional later; needs access to the user's pi credentials); guard-only control with the user's Fabric config |
| D17 | **Stage A exit gate amended**: sanitized replay fixtures (A7) are optional | The scripted fake pi covers CI and the live suite covers qualification; a fixture sanitizer adds no safety now | Blocking stage B on A7 |
| D18 | **Process groups** for everything a worker starts. pi runs under a `setsid` launcher (Perl `POSIX::setsid` + `exec`: pi's pid is its group id). pi's bash tool runs each command in its **own new session** (`detached: true`), so `bm_guard` also prefixes every authorized bash command with a line that appends `$$` (that session's group id) to a per-attempt file (`BM_PGID_FILE`). Settling, stop and recovery check and kill **all recorded groups** | Background jobs keep their group id after re-parenting to PID 1 (`nohup … &` and `( … &)` verified); macOS has no `setsid` binary and `ps -E` can't read other processes' environment, so group ids are the handle | Descendant-tree checks (miss re-parented processes); an environment marker (unreadable on macOS); only pi's own group (misses every bash command) |
| D19 | **Snapshots are git trees** written from a private index (`<git-dir>/bm/index`): `read-tree HEAD` once, then `add -A` + `write-tree`. Write sets are `diff-tree` between two trees; checkpoints reuse the verified tree | One mechanism for D11 and D12; git's stat cache makes repeated snapshots cheap; trees also give exact content for conditional restore | Hashing every file in Elixir |

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
│    Port · RPC · dialogs · session epoch · health · process-group kill           │
│                                                                                 │
│  Limits (budget, timeouts, repeat guard) · Postgres (authoritative) · ETS       │
└──────┬───────────────────────────────┬─────────────────────────┬────────────────┘
       │ RPC                           │ RPC                     │ RPC
  pi planner                    pi read-only worker(s)      pi mutating worker (≤1)
  zro + bm_planner              zro + bm_worker             zro + bm_worker + bm_guard
                                no edit/write/bash tools    edit/write/bash via guard
                                (parallel: optional)
                        all share ONE checkout
```

Process boundaries follow state ownership: one workspace coordinator per checkout, one adapter
process per pi process. With one active run per workspace (D4), the core keeps the run
coordinator's state inside the workspace coordinator; it becomes its own process only if a
workspace ever runs more than one run. Other pieces (scheduler, validator, git helpers)
are plain modules called by their owner, not separate processes.

---

## 4. Roles and profiles

| Role | Extensions | Tools | Memory |
|---|---|---|---|
| Planner | zro, `bm_planner` | read-only pi tools + `propose_task`, `close_plan` | ~134 MB |
| Read-only worker | zro, `bm_worker` | `read`, `grep`, `find`, `ls`, `submit_result` | ~134 MB |
| Mutating worker | zro, `bm_worker`, `bm_guard` | read tools, `edit`, `write`, policed `bash`, `submit_result` | ~134 MB |
| Reviewer (optional) | zro, `bm_worker` | read-only + `submit_result` | ~134 MB |

Every agent is started with `--no-extensions`, an explicit `-e` list, a `--tools` allowlist and a
pinned model (`Bm.Pi.Profile`). **Profile check before assignment:** `bm_worker`/`bm_planner`
report the active tools on start (`bm_guard` reports too in the writer profile); the check
compares them and the model with the profile, and pi's version with the pinned one. A mismatch
fails closed (the agent is stopped and the attempt is not started). With Fabric not loaded (D16),
Fabric's agent spawning and nested calls don't apply; if Fabric is re-added, its spawning must be
off through configuration (`agents.maxDepth: 0`), with `PI_FABRIC_DEPTH` only as an extra guard.

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
                        ╰───────────────────────────────╯                 ╰─▶ held
in flight (admitted … verifying) ─▶ failed | cancelled | needs_reconciliation
held ─▶ accepted (Keep) | reverted (Revert)
failed | cancelled | needs_reconciliation | accepted ─▶ reverted  (latest attempt only)
```

The table is `Bm.Runs.Attempt.transitions/0`. `running ─▶ settling` covers a worker that stopped
without a result. Tasks have their own statuses (`queued`, `running`, `accepted`, `failed`,
`blocked`, `cancelled`); a task is `blocked` when a dependency failed.

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

**Baseline and dirty policy.** At run start the coordinator records HEAD, a snapshot tree (D19)
and every modified, staged or untracked (non-ignored) path. Those files are **user-owned** for the
run: agents may read them; a task that needs to change one is blocked and reported. BM never
stages, stashes or commits user changes.

**Mutation lane.** At most one attempt runs at a time in the core (D5); tasks run sequentially.
Parallel read-only attempts are an optional feature.

**Attribution by snapshot (D11, D19).** Before an attempt starts and after it settles, the
coordinator writes a snapshot tree of the workspace from BM's private index. `git diff-tree`
between the two trees is the attempt's **actual write set**, whatever tool or command produced it.
It is compared with the **declared** write set; writes outside it are flagged for review, and
writes to user-owned files fail the attempt.

**Settling (D18).** An attempt is settled when pi reports `agent_settled`, no tool is running, and
no process is left in pi's own group or in any group recorded in the attempt's `BM_PGID_FILE`.
Leftovers after a short grace period are killed by group and the attempt is flagged.

**Verification barrier.** With the lane still held, the coordinator runs the workspace's
**verify command** (configured per workspace, e.g. `mix precommit`; run as its own process group
with a timeout), then records a **checkpoint**: a commit of the verified snapshot tree stored
under `refs/bm/runs/<run>/<n>`. HEAD, the branch and the user's index are untouched. The checkpoint
id is the exact state that was verified. A failed verification **holds** the lane until the user
chooses Keep or Revert. Note: `refs/bm/…` include untracked non-ignored files and are pushed by
`git push --mirror`; pruning old refs is an optional feature.

**Revert (core).** Only the latest attempt can be reverted: restore its write set from its
`tree_before`, only if every file still equals its content in `tree_after`; created files are
removed and deleted files restored under the same check. Any newer or external change stops the
revert and asks the user. The revert is all or nothing even against edits made while it runs:
files are moved aside atomically, re-checked, and the old contents written with exclusive create;
any failure undoes every step (`Bm.Workspace.Git.restore/5`). Per-task rollback with dependency handling is optional.

**Freshness (optional, from fx).** A later addition: `bm_guard` would record the content hash of
every file the worker reads and block `edit`/`write` when the file changed since. Not in the core,
because with one writer the snapshots already catch concurrent user edits after the fact.

---

## 8. Guarantees (V1) and their enforcement

| Guarantee | Enforced by | Not guaranteed |
|---|---|---|
| No two BM workers change files at the same time | Mutation lane (D5) | — |
| Read-only workers can't change files through pi tools | Tool allowlist per profile | MCP tools or extensions outside the profile (profiles exclude them) |
| Every change a mutating attempt makes is attributed to it | Before/after snapshots | Changes the *user* makes during that attempt are also attributed to it; the UI warns (the optional freshness check would catch edits to files the worker read) |
| No process started by a worker outlives its attempt | Recorded process groups (D18), group kill on settle/stop/recovery; a group seen empty is never signalled again, and recovery ignores groups from an earlier boot (reused ids) | A command that starts a **new session** itself (`setsid`, double fork + setsid) escapes; the policy refuses `setsid`, but this is not a sandbox |
| User changes are never committed, stashed or overwritten by BM | Baseline policy, private-index checkpoints, conditional rollback | A shell command inside a mutating attempt could still overwrite a user-owned file; it is detected (snapshot) and the attempt fails, but the overwrite already happened |
| Accepted means verified | Verification barrier + checkpoint id | Test coverage decides what "verified" catches |
| Stale messages can't affect a new attempt | Attempt ids + session epoch | — |
| Spending stays near the budget | Admission stops at the limit; hard limit aborts | Requests already in flight can exceed it; missing cost is "unknown", never 0 |

Command policy (`Bm.Policy`, asked by `bm_guard` for every edit, write and bash call) blocks
known-dangerous commands (git writes, `setsid`, `sudo`, publishing), and applies the same path
rules to edit/write and to files a shell command visibly writes (redirects, `tee`, `sed -i`,
`cp`/`mv`/`install`/`ln` destinations, `rm`): inside the checkout, not `.git`, not user-owned.
It is a safety net, not a sandbox.

---

## 9. Data model

Postgres (authoritative):

Core tables (see IMPLEMENTATION_PLAN.md step 2.1 for columns):

- `workspaces`: canonical path, verify command, settings
- `runs`: workspace, goal, status, plan_open, budget, spent (confirmed) and unknown count, baseline
  (HEAD, tree, user-owned paths). A partial unique index on active runs per workspace is the run lock
- `tasks`: run, key, revision, title, goal, done_when, mutates, declared writes, depends_on, status
- `attempts`: task, number, role, agent, session_epoch, process groups, status, tree_before/after,
  actual_writes, result, verification, checkpoint ref
- `bridge_requests` (implemented): request_id, agent, role, op, session epoch, attempt, payload,
  outcome (idempotency for dialogs)
- `deliveries`: target, message, received_at, delivered_at

Optional later: `items` (ordered event log for UI replay and history), separate `checkpoints`.

ETS (projections): live agent status, lane occupancy, counters.

---

## 10. Limits and observability

Core:

- Budget: confirmed spend from pi's `usage.cost`; entries without cost are counted as unknown,
  never as 0. Admission stops at the hard cap, and crossing it aborts the running attempt.
- Time limits per attempt: a maximum duration, and a stall timeout (no pi event while no tool runs
  and no dialog is pending).
- Bounded buffers: RPC line buffer, pending requests, transcripts, logs (implemented in A1).
- Raw RPC logs are sensitive (prompts, paths, file contents) and are not committed.

Optional: soft budget limit, in-flight estimates, timeouts per state (provider wait, running tool,
approval wait), a repeat-call guard (same call and arguments K times in a row → abort), sanitized
replay fixtures.

---

## 11. Recovery

**Core (minimal).** At application start, before accepting work: for every attempt that was in
flight, kill its recorded process groups, write a snapshot and compare it with the attempt's
`tree_before`. No change → `failed` (reason `interrupted`, safe to run again); any change →
`needs_reconciliation` for the user, who can Keep or Revert. The run is paused. An attempt that
may have changed files is never retried automatically.

**Optional.** Resume attempts in place, and reconcile against the last checkpoint automatically.

---

## 12. Status

**Implemented (milestone A, A1–A6).** Tests use the scripted fake pi; the live suite
(`mix test --only live`, 4/4) uses the real pi and model.

- `Bm.Pi.Agent`: Port, RPC events, transcript, extra env, raw log. Commands (`prompt`,
  `follow_up`, `new_session`, `abort`) wait for pi's `success`; confirmed cost and unknown usage
  tracked; bounded line buffer, pending requests, transcript and raw log; session epoch; graceful
  stop via `/bm-shutdown` before any kill.
- `Bm.Pi.ToolCalls`: streamed tool calls are **proposals** only.
- `Bm.Bridge` + `bridge_requests`: authoritative `bm:` dialogs, role check, persisted before the
  answer, idempotent by `request_id`, identity from the channel.
- `Bm.Pi.Profile`: planner / reader / writer profiles, Fabric-free (D16), fail-closed profile check,
  pinned pi version.
- Extensions: `bm_common` (dialog and notify helpers, `/bm-shutdown`), `bm_planner`
  (`propose_task`, `close_plan`), `bm_worker` (`submit_result`), `bm_guard` (asks the BEAM before
  every edit, write and bash call; fails closed).
- Chat page and canvas with one agent node.
- Process groups (Phase 1, D18): `priv/pi/setsid.pl`, `Bm.Proc`; pi starts as a group leader,
  `bm_guard` records every bash command's group in `BM_PGID_FILE`, and all groups are ended when
  pi exits or the agent stops.

- Git layer (Phase 3): `Bm.Workspace.Git` with snapshots from a private index, write sets
  (`diff-tree`), baselines of user-owned paths, checkpoints under `refs/bm/…`, and conditional
  restore (content, mode and symlinks). Works only at a repository's top level.
- Persistence (Phase 2): `Bm.Runs` with workspaces (canonical paths), runs (one unfinished run
  per workspace, enforced by a partial unique index), tasks, attempts and the attempt state
  machine (`Bm.Runs.Attempt.transitions/0`, compare-and-set transitions). `Bm.Bridge.handle/5`
  fences requests by the owner's assignment (`stale`, `not_assigned`) and records the attempt.

- Workspace coordinator (Phase 4): `Bm.Workspace.Coordinator`, one per checkout, runs one
  attempt at a time through start (profile check) → guarded run (`Bm.Policy` answers
  `bm:authorize`; `submit_result` persisted and fenced) → settling (process groups) → snapshot
  attribution → verify command (own process group, timeout) → checkpoint; cancel and Keep; the
  lane is held after changes BM could not accept. Tested with the scripted fake pi.

- Limits, revert, recovery (Phase 5): hard budget cap from confirmed spend (unknown tracked),
  attempt time limit and stall timeout, revert of the latest attempt, and minimal recovery at
  application start and coordinator start (`Bm.Workspace.Recovery`).

- UI (Phase 6): Tasks page and run page (live attempts, diffs, verification, Stop / Keep /
  Revert / Finish); the prototype chat at `/chat` is not guarded by BM. Milestone B exit gate
  passed live; `mix bm.bench` compares plain pi with BM (docs/BENCHMARK.md).

**Not implemented yet:** the planner flow (milestone C). The coordinator is not yet reachable from the
UI. A7 (replay fixtures) is optional (D17).

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
| macOS has no `setsid` binary; `perl -MPOSIX -e 'setsid() or die; exec @ARGV'` makes the exec'd program leader of a new session and group with pid = pgid | 2026-09-29, `ps -o pid,pgid,sess` |
| In a non-interactive shell, `nohup … &` and `( … &)` keep the shell's process group after the shell exits and they are re-parented to PID 1; `kill -- -<pgid>` still reaches them | 2026-09-29, scratch test |
| **pi's bash tool spawns every command with `detached: true`** (new session per command) and kills it by group on abort or timeout; commands are not in pi's group | pi 0.87.1 `dist/core/tools/bash.js:52`, `utils/shell.js:184` |
| `ps -E` doesn't show another process's environment on this macOS, even unsandboxed, so environment markers can't identify a worker's processes | 2026-09-29, scratch test |
| pi `tool_call` handlers may **mutate the tool input** as well as block it | pi `docs/extensions.md:103` |
| pi's shell is configurable only through settings (`shellPath`, `shellCommandPrefix` in `~/.pi/agent/settings.json` or the project's `.pi/settings.json`), which would touch the user's config or checkout | pi `docs/shell-aliases.md` |
| A plain `git status` rewrites the user's `.git/index` (stat-cache refresh); `GIT_OPTIONAL_LOCKS=0` prevents it | 2026-09-29, scratch repo and `Bm.Workspace.GitTest` |
| Snapshot of this repository (private index, `add -A` + `write-tree`): first 47 ms, second 31 ms | `mix test --only perf`, 2026-09-29 |
| `git add -A` from a subdirectory snapshots only that subdirectory (and fails if the parent repo ignores it), so the git layer requires the repository's top level | `Bm.Workspace.GitTest` |
| A `tool_call` hook's in-place change of `event.input` affects only execution: pi validates into a `structuredClone` before hooks run and emits `tool_execution_start` with the model's original arguments, so the model's history and BM's transcript keep the original bash command | pi-agent-core `agent-loop.js` (`executeToolCallsSequential`, `prepareToolCall`), pi-ai `validation.js:281` |

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
   can't see it (reproduced live). Refined in Phase 0 (2026-09-29): pi runs each bash command in
   its own session, and background jobs keep that session's group id, so tracking the group id of
   every bash command catches them (D18). Only a process that creates a new session itself
   escapes; the policy refuses `setsid`, which is a safety net, not a sandbox.
6. Which settings in the user's `fabric.json` affect workers: **moot** while workers are
   Fabric-free (D16); reopen if Fabric is re-added.

Still open:
7. How well does GLM 5.3 declare write sets? (Affects the undeclared-write flag and, later,
   parallel writers.)
8. Cost, time and success versus a single pi on the same tasks (benchmarks in plan steps 6.5 and
   8.3).
9. Prefixing the bash command in `bm_guard`'s `tool_call` hook works under real pi: **yes**
   (live, 2026-09-29). The BEAM authorizes the model's original command, the model sees the
   command's normal output, the recorded group is not pi's, a `nohup … &` job is still found
   after `agent_settled`, and stopping the agent ends it. Moved to "answered" with plan step 1.4.
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
| `lib/bm/pi/profile.ex` | Controlled profiles and the fail-closed profile check |
| `lib/bm/pi/tool_calls.ex` | Streamed tool-call assembler (proposals) |
| `lib/bm/pi/transcript.ex` | Transcript reducer |
| `lib/bm/proc.ex`, `priv/pi/setsid.pl` | Process groups: launcher, members, group kill, `BM_PGID_FILE` |
| `lib/bm/workspace/git.ex` | Snapshots, write sets, baseline, checkpoints, conditional restore |
| `lib/bm/workspace/coordinator.ex` | Workspace coordinator: mutation lane and the attempt lifecycle |
| `lib/bm/workspace/recovery.ex` | Recovery of attempts left in flight |
| `lib/bm/policy.ex` | Decides the worker's edit/write paths and bash commands |
| `lib/bm/prompts.ex` | Worker prompt |
| `lib/bm/workspace/verify.ex` | Runs the verify command as its own process group |
| `lib/bm_web/live/home_live.ex`, `lib/bm_web/live/run_live.ex`, `lib/bm_web/components/run_components.ex` | Tasks page, run page, status badges and diffs |
| `lib/mix/tasks/bm.bench.ex` | Benchmark: plain pi vs BM |
| `test/live/milestone_b_test.exs` | Milestone B exit gate (live) |
| `lib/bm/runs.ex`, `lib/bm/runs/` | Workspaces, runs, tasks, attempts (Postgres) and the attempt state machine |
| `lib/bm/bridge.ex`, `lib/bm/bridge/request.ex` | Authoritative dialog handling and its persisted requests |
| `priv/pi/extensions/bm_common.ts` | Dialog/notify helpers and `/bm-shutdown` (not an extension) |
| `priv/pi/extensions/bm_planner.ts` | `propose_task`, `close_plan` |
| `priv/pi/extensions/bm_worker.ts` | `submit_result` |
| `priv/pi/extensions/bm_guard.ts` | Asks the BEAM before edit, write and bash |
| `lib/bm_web/live/chat_live.ex`, `lib/bm_web/live/flow_live.ex`, `assets/svelte/` | Prototype chat (not guarded) and canvas |
| `test/support/fake_pi.mjs` | Scripted pi stand-in |
| `test/live/qualification_test.exs` | Live qualification suite (`mix test --only live`) |

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
