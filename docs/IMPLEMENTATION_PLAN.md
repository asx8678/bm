# BM core implementation plan

Written 2026-09-29. Implements the **core** of [FEATURES.md](FEATURES.md) (milestones B and C).
Design reference: [ARCHITECTURE.md](ARCHITECTURE.md).

## Rules for every step

- One step = one commit, small enough to review in a few minutes.
- Each step ends with a **Verify** check. It must pass before the next step starts; `mix precommit`
  must pass too.
- Tests use the scripted fake pi (`test/support/fake_pi.mjs`) and throwaway git repos in
  `System.tmp_dir!()`. Only steps marked **live** call the real model (`mix test --only live`).
- Pure modules first (git, policy, validation), processes second, UI last.
- When a step changes a decision, add a row to ARCHITECTURE.md §2 in the same commit.

## Overview

| Phase | Goal | Steps | Ends with |
|---|---|---|---|
| 0 | Docs match the code | 0.1–0.2 | — |
| 1 | Process groups | 1.1–1.4 | pi and everything it starts can be listed and killed |
| 2 | Persistence | 2.1–2.4 | runs, tasks, attempts, fencing in Postgres |
| 3 | Git layer | 3.1–3.6 | snapshots, write sets, checkpoints, restore; user state untouched |
| 4 | Workspace coordinator | 4.1–4.9 | one task end-to-end with the fake pi |
| 5 | Limits, revert, recovery | 5.1–5.4 | runaways stopped; crashes end in reconciliation |
| 6 | Run page and milestone B gate | 6.1–6.5 | **Milestone B exit gate** (live) + mini-benchmark |
| 6.6 | Hardening before the planner (review of 2026-09-29) | 6.6.1–6.6.5 | UI seen, harder benchmark, write-set data, baseline verify |
| 7 | Planner | 7.1–7.9 | goal → plan → sequential tasks with the fake pi |
| 8 | Plan UI and milestone C gate | 8.1–8.4 | **Milestone C exit gate** (live) + benchmark |
| 9 | Optional: goal-run overhead | 9.0–9.4 | fewer planner round-trips; benchmark before/after |
| 10 | Optional: seeing a run | 10.1–10.6 | live run canvas, live worker activity, checkpoint pruning, attempt transcripts, run search, failed checks re-planned |
| 11 | Real repositories | 11.1–11.5 | supervised trial goals on real code, fixes, revert a whole run, refined limits |
| 12 | Better plans, fewer failures | 12.1–12.3 | run labels, `ask_planner` for workers, goal review before planning |
| 13 | Safety during long runs | 13.1–13.3 | protect files edited during a run, freshness check on write, undo one task |
| 14 | Quality gate and terminal use | 14.1–14.3 | reviewer before accepting (D25), local JSON API, `mix bm.*` client |
| 15 | Daily use | 15.1–15.3 | commit a run's changes on request (D26), one suite run, trial on the user's project |

---

## Phase 0: docs match the code

**0.1 Remove stale statements after D16.** ARCHITECTURE.md: intro, principle 2 and D2 (no BM
agent loads Fabric now); §3 diagram (workers are `zro + bm_worker [+ bm_guard]`); §4 (drop the
`agents.maxDepth` requirement for workers); §12 status (A1–A6 done, `bm_bridge` gone); §16 code map
(`bridge.ex`, `profile.ex`, `bm_common/planner/worker/guard.ts`); §14 question 6 closed by D16;
move D15 above D16.
Verify: `grep -n "bm_bridge\|zro + Fabric" docs/ARCHITECTURE.md` finds only history (Appendix A).

**0.2 Record decisions D17–D19.**
- D17: Stage A gate amended: replay fixtures (A7) are optional; the fake pi + live suite suffice.
- D18: Process groups. pi runs under a `setsid` launcher (Perl `POSIX::setsid` + `exec`, so pi's
  pid is its group id). pi's bash tool starts **each command in its own session**, so `bm_guard`
  also prefixes every authorized bash command with a line that records `$$` (the command's group
  id) in `BM_PGID_FILE`. Verified 2026-09-29: `nohup … &` and `( … &)` keep that group id after
  re-parenting to PID 1, and a group kill reaches them; only an explicit new session escapes.
- D19: Snapshots are tree ids written from a private index (`.git/bm/index`); write sets are tree
  diffs; checkpoints reuse those trees.
Verify: rows present in §2; §13 gains the nohup/process-group fact.

---

## Phase 1: process groups

**1.1 Launcher.** `priv/pi/setsid.pl`: `use POSIX; setsid() or die; exec @ARGV or die`.
Verify (test `test/bm/proc_test.exs`): run `setsid.pl sh -c 'ps -o pgid= -p $$'` through a Port;
the printed pgid equals the Port's `os_pid`.

**1.2 `Bm.Proc` module** (`lib/bm/proc.ex`): `group_members(pgids)` (parse `ps -A -o pid=,pgid=`),
`signal_groups(pgids, signal)` (`kill -SIG -- -pgid`, ignoring groups already gone),
`await_groups_empty(pgids, timeout)`, `read_pgid_file(path)`.
Verify: start `setsid.pl sh -c 'nohup sleep 30 >/dev/null 2>&1 & (sleep 30 &); exit'`; after the
shell exits `group_members` still lists 2 processes; `signal_groups(:TERM)`; `await_groups_empty`
returns `:ok` within 1 s.

**1.3 Agent uses the launcher.** `Bm.Pi.Agent.open_port/1` prefixes the command with the launcher,
creates a per-process `BM_PGID_FILE` (in the agent's private tmp dir) and passes it in the env.
`summary/1` exposes `pgid` and `pgid_file`. On stop, after the graceful shutdown and PID kill
already in `terminate/2`, signal pi's group and every recorded group (TERM, then KILL) and wait
until all are empty.
Verify: fake pi gains a `spawn-child` script that mimics pi's bash tool: it spawns
`sh -c 'printf "%s\n" "$$" >> "$BM_PGID_FILE"; nohup sleep 60 >/dev/null 2>&1 &'` with
`detached: true`, then answers. Test: prompt `spawn-child`, `Bm.Pi.stop/1`, then no process is
left in any recorded group. Existing `pi_test.exs` still passes.

**1.4 Guard records bash groups.** `bm_guard.ts`: when the BEAM allows a `bash` call, mutate
`event.input.command` to `printf '%s\n' "$$" >> "$BM_PGID_FILE"\n<original command>` (fail
closed if `BM_PGID_FILE` is unset). **Live**: extend `qualification_test.exs`: the writer runs
`nohup sleep 30 >/dev/null 2>&1 &`; after `agent_settled` the recorded group still has a member;
after `Bm.Pi.stop/1` it is empty. Also check the tool result shown to the model is the command's
normal output.
Verify: `mix test --only live` passes (4/4: this test replaces the old descendant-tree finding);
answer open question 9 in ARCHITECTURE.md §14.

**Status: Phase 1 done (2026-09-29).**

---

## Phase 2: persistence

**2.1 Schemas and migration** (`mix ecto.gen.migration create_runs`).
- `workspaces`: `path` (unique, canonical), `verify_command` (string), `settings` (map)
- `runs`: `workspace_id`, `goal`, `status` (`active | paused | done | failed | cancelled`),
  `plan_open` (bool), `budget_usd`, `spent_usd`, `spent_unknown` (int), `baseline` (map:
  `head`, `tree`, `user_owned` list)
- `tasks`: `run_id`, `key`, `revision`, `title`, `goal`, `done_when`, `mutates`, `writes` (array),
  `depends_on` (array), `status`; unique `(run_id, key, revision)`
- `attempts`: `task_id`, `number`, `role`, `agent_id`, `session_epoch`, `pgid` (pi), `pgid_file`, `status`,
  `tree_before`, `tree_after`, `actual_writes` (array of maps), `result` (map), `verify` (map:
  exit, output tail), `checkpoint_ref`, `error`
- A **partial unique index** on `runs(workspace_id) WHERE status IN ('active','paused')` is the
  one-run-per-workspace lock.
Context: `Bm.Runs` with schemas under `lib/bm/runs/`.
Verify: `mix ecto.migrate` and `mix ecto.rollback` both work; changeset tests for required fields.

**2.2 Run lifecycle.** `Bm.Runs.start_run(workspace, goal, opts)`, `finish_run/2`,
`cancel_run/1`, `get_active_run(workspace)`.
Verify: starting a second active run on the same workspace returns `{:error, :workspace_busy}`
(from the unique index); after `finish_run` a new run starts.

**2.3 Attempt state machine.** `Bm.Runs.Attempt.transition(attempt, to)` with an explicit table:
`queued → admitted → running → result_received → settling → verifying → accepted`, and
`admitted | running | result_received | settling | verifying → failed | cancelled |
needs_reconciliation`; `verifying → held` (failed verification, waiting for Keep/Revert);
`held → accepted | reverted`. Illegal transitions return `{:error, {:illegal, from, to}}`.
Verify: table-driven test over every pair.

**2.4 Fencing in the bridge.** Add `attempt_id` to `bridge_requests` (new migration).
`Bm.Bridge.handle/4` receives the current assignment (`attempt_id`, `session_epoch`) from the
caller; a request arriving with an epoch that differs from the assignment's returns
`%{"ok" => false, "error" => "stale"}`, and one arriving when nothing is assigned (or a worker
without an attempt) returns `"not_assigned"`; neither runs nor persists anything.
Verify: `bridge_test.exs`: stale epoch rejected; no assignment rejected; duplicate `request_id`
still returns the stored outcome.

**Status: Phase 2 done (2026-09-29).** Notes: attempts may also go `running → settling` (worker
stopped without a result) and `accepted → reverted` (revert of the latest attempt, checked by the
coordinator); `Bm.Runs.transition_attempt/3` applies a move only if the stored status is unchanged
(`{:error, :stale}` otherwise); workspace paths are canonical (symlinks resolved).

---

## Phase 3: git layer (pure functions, throwaway repos)

All in `lib/bm/workspace/git.ex`; every function takes the repo path. Tests in
`test/bm/workspace/git_test.exs` build a repo with: one commit, one **staged** user change, one
**unstaged** modification, one **untracked** file, one ignored file.

**3.1 Snapshot.** `snapshot(repo) :: {:ok, tree_id}`. Uses `GIT_INDEX_FILE=<git-dir>/bm/index`:
first time `git read-tree HEAD` (or `--empty` without HEAD), then `git add -A`, then
`git write-tree`.
Verify: tree contains the staged, unstaged and untracked content, not the ignored file;
`.git/index` bytes, `git rev-parse HEAD`, the branch and `git diff --cached` are unchanged; a second
snapshot with no changes returns the same tree id; works in a repo with no commits.

**3.2 Write set.** `diff(tree_a, tree_b) :: [%{path, status: :added | :modified | :deleted}]` via
`git diff-tree -r -z --no-renames --name-status`.
Verify: create, modify, delete one file each between two snapshots → three entries; paths with
spaces and newlines survive (`-z`).

**3.3 Baseline.** `baseline(repo) :: %{head, tree, user_owned}`, where `user_owned` is every path
that differs between HEAD and the working tree or index, plus untracked non-ignored files
(`git status --porcelain=v1 -z --untracked-files=all`).
Verify: `user_owned` is exactly the staged, unstaged and untracked paths from the fixture.

**3.4 Checkpoint.** `checkpoint(repo, tree, parent, ref, message) :: {:ok, commit}` via
`git commit-tree` + `git update-ref refs/bm/runs/<run>/<n>`. Parent is the previous checkpoint or
HEAD.
Verify: `git cat-file -p <ref>` shows the tree; HEAD, branch, `.git/index` and `git status`
output are unchanged; `git log` on the branch doesn't show it.

**3.5 Conditional restore.** `restore(repo, entries, from_tree, expected_tree)`: for every entry,
the current file must hash (`git hash-object`) to its blob in `expected_tree` (or be absent if it
was deleted); if any differ, return `{:error, {:changed_since, paths}}` and change nothing;
otherwise write each file from `from_tree` (`git cat-file blob`) or delete it if it's absent there.
Verify: revert restores all three kinds of change; after the user edits one of the files, revert
refuses and no file changes.

**3.6 Speed check.** A test tagged `:perf` snapshots this repository twice.
Verify: second snapshot < 1 s on this machine; record the numbers in ARCHITECTURE.md §13.

**Status: Phase 3 done (2026-09-29).** Notes: every function requires the repository's top level
(`{:error, {:not_repository_root, top}}` otherwise), so Phase 4 must create workspaces at the
top level; restore also handles file modes and symlinks and uses `cat-file --filters` (checkout
conversions); checkpoints use BM's own identity and `--no-gpg-sign`; `mix test --only perf`
runs the timing check.

**Review (2026-09-29).** A re-check of phases 0–3 found and fixed: restore refused to revert a
file that an attempt turned into a directory, crashed on a path below a file (`:enotdir`), and
didn't accept write sets as stored in Postgres (string keys); ARCHITECTURE.md §6 still showed the
old attempt lifecycle. Restore now deletes deepest-first before writing, and replaces a directory
only if every file in it is being deleted.

**Follow-up fixes (2026-09-29).** Restore is all or nothing also against concurrent edits
(move aside, re-check, exclusive create, undo on failure). Process groups: `Bm.Pi.process_groups/1`
returns live groups and never returns a group seen empty (reused ids); attempts store `boot_id`
so recovery never signals groups from an earlier boot. Checked: `bm_guard`'s command prefix is not
visible to the model or in BM's transcript (pi hooks run on a clone of the arguments).

---

## Phase 4: workspace coordinator (fake pi)

**4.1 Fake pi learns to "work".** New script `work:<json>` in `fake_pi.mjs`, where the JSON lists
steps: `{"authorize": {tool, input}}` (sends a `bm:authorize` dialog and stops if denied),
`{"write": [path, text]}` (writes the file itself, simulating the tool), `{"spawn": "sleep 60"}`,
`{"submit": {status, summary}}` (sends `bm:submit_result`), `{"hang": true}`.
Verify: a `pi_test.exs` case drives each step and sees the expected dialogs and file.

**4.2 Policy (pure).** `Bm.Policy.authorize(tool, input, ctx) :: :allow | {:deny, reason}` with
`ctx = %{root, user_owned, declared_writes}`.
- `edit`/`write`: path must resolve (symlinks and `..` included) inside `root`, and must not be
  user-owned. Outside the declared set is *allowed* but flagged later by the write set.
- `bash`: deny `git` subcommands that write (`add commit push checkout switch reset restore stash
  rebase merge cherry-pick tag branch -D clean`), `setsid`, `sudo`, `rm -rf` of `/` or `~`.
Verify: table-driven tests, including the paths `../x`, `/etc/x`, a symlink leaving the root,
and a user-owned file.

**4.3 Coordinator process.** `Bm.Workspace.Coordinator` (GenServer, one per workspace path,
registered in a `Registry`, under a `DynamicSupervisor`). State: workspace, run, current attempt,
lane (`:free | {:busy, attempt} | {:held, attempt}`).
API: `ensure_started(path)`, `run_task(path, task_attrs)`, `state(path)`.
Verify: two `ensure_started` calls give one pid; `state` returns lane `:free`.

**4.4 Admission.** `run_task` creates the run (if none), the task and the attempt, takes the lane,
records `tree_before`, starts the writer via `Bm.Pi.Profile.start(agent_id, :writer, owner:
coordinator, cwd: path)`, stores `session_epoch`, `pgid` and `pgid_file`, sends the prompt from
`Bm.Prompts.worker(task)` and moves the attempt to `running`. A busy lane returns
`{:error, :lane_busy}`.
Verify: with the fake pi, the attempt is `running`, the agent's cwd is the repo, a second
`run_task` gets `:lane_busy`.

**4.5 Requests.** The coordinator handles `{:pi_request, agent_id, request}`: `authorize` →
`Bm.Policy`; `submit_result` → store in `attempts.result`, move to `result_received`; both go
through `Bm.Bridge.handle/4` with the current assignment.
Verify: a denied `authorize` leaves no file (fake `work` stops); `submit_result` is persisted
once even when the fake sends it twice.

**4.6 Settling.** Settled = `agent_settled` seen + no running tool + no process in any group recorded in `pgid_file`
(and none in pi's group but pi), polled every 200 ms up to 10 s. After that the worker is stopped (graceful,
then group kill), then `tree_after` → `actual_writes`. An attempt is failed if it wrote a
user-owned file; writes outside the declared set are flagged.
Verify: `work` with `spawn` settles only after the child is killed and the attempt records the
flag `leftover_processes`; a write to a user-owned file fails the attempt; a write outside the
declared set sets `flags: ["undeclared_writes"]`.

**4.7 Verification.** With the lane still held, run `workspace.verify_command` in the repo through
the launcher (so it can be killed as a group), with a timeout; store exit status and the last
4 KB of output.
Verify: `verify_command: "true"` → `verifying → accepted` path; `"false"` → `held`; a sleeping
command past the timeout → `held` with `error: "verify_timeout"` and no process left.

**4.8 Checkpoint and completion.** On pass: `Git.checkpoint(tree_after)` → `checkpoint_ref`,
attempt `accepted`, lane `:free`. On `held`: lane stays `{:held, attempt}` until `keep/1`
(→ `accepted`, checkpoint recorded as unverified-kept) or `revert/1` (Phase 5.3).
Verify: after an accepted attempt, `refs/bm/runs/<run>/1` exists and the user's staged change is
still staged (`git diff --cached` unchanged).

**4.9 Cancel.** `cancel(path)`: `Bm.Pi.abort`, stop the worker, group kill, snapshot, record the
write set, attempt `cancelled`, lane `:free` if nothing was written, else `{:held, attempt}`.
Verify: cancel during `hang` → `cancelled` with an empty write set; cancel after a `write` → held
with that file in `actual_writes`.

**Status: Phase 4 done (2026-09-29).** Decisions made while building it:
- A workspace needs a `verify_command` (`run_task` returns `{:error, :no_verify_command}`); there
  is no "accepted without verification" for changes.
- An attempt that changed nothing is accepted without running verification and without a
  checkpoint (`verify: %{"skipped" => "no changes"}`): the workspace is as it was.
- The lane is also held after a **failed** or **cancelled** attempt that left changes, until Keep
  or Revert. Keep on a `held` attempt accepts it with a checkpoint marked "kept, unverified"; on a
  failed/cancelled one it only adds the `kept` flag and frees the lane.
- Tasks with `mutates: false` run with the reader profile; any write fails them.
- `bm_guard` sends only the path (edit/write) or the command (bash) to the BEAM, never file
  contents; authorizations are persisted in `bridge_requests` as an audit log.
- Starting/stopping pi and verification run in `Bm.TaskSupervisor` tasks, so the coordinator keeps
  answering the worker and can cancel at any phase; the coordinator monitors the pi adapter and
  ends recorded groups itself if the adapter dies.

**Review (2026-09-29).** Fixed after a re-check: files changed by the verify command (formatters,
generators) now belong to the attempt and its checkpoint (flag `verify_changed_files`), and
changes to the user's files by verification hold the lane; verify output is stored as valid
UTF-8 (invalid bytes crashed the coordinator); a cancel during start ends as `cancelled`; an
adapter that dies right after start no longer crashes the coordinator; admission is one
transaction, so a failed admission leaves no task, attempt or run. Open for phase 5: a restarted
coordinator must recover in-flight attempts before it frees the lane (step 5.4).

---

## Phase 5: limits, revert, recovery

**5.1 Budget cap.** The coordinator adds the agent's confirmed spend and unknown count to the run
(from agent summaries). Admission refuses when `spent_usd >= budget_usd`; crossing it during an
attempt aborts it (→ `cancelled`, reason `budget`).
Verify: fake cost is 0.003 per answer; budget 0.005 → the second attempt is refused; a `nocost`
answer increments `spent_unknown` and never counts as 0.

**5.2 Time limits.** Per attempt: `max_duration` (default 20 min) and `stall` (default 3 min
without any pi event while no tool is running and no dialog is pending). Either one cancels the
attempt with a reason.
Verify: with 200 ms test settings, `hang` is cancelled with reason `stall`; a long `work` with
events is cancelled with reason `max_duration`.

**5.3 Revert the latest attempt.** `revert(path)`: allowed only for the latest attempt of the run;
uses `Git.restore(actual_writes, tree_before, tree_after)`. On success the attempt becomes
`reverted` and the lane is freed; on `{:changed_since, …}` nothing changes and the UI asks the user.
Verify: revert a held attempt → files back to `tree_before`; edit a file after the attempt → revert
refuses and the file keeps the user's edit.

**5.4 Minimal recovery.** `Bm.Workspace.Recovery.run/0` at application start (before the endpoint):
for every attempt in `admitted | running | result_received | settling | verifying`: if the
attempt's `boot_id` equals `Bm.Proc.boot_id()`, group-kill pi's
group and every group in its `pgid_file` that still has members, snapshot, compare with `tree_before`: no change → `failed`
(reason `interrupted`, safe to re-run); change → `needs_reconciliation` with the write set. The run
becomes `paused`.
Verify: insert a `running` attempt with a live `sleep` group and a modified file; `Recovery.run/0`
kills the group and marks it `needs_reconciliation`; an untouched one becomes `failed`.

**Status: Phase 5 done (2026-09-29).** Notes:
- Budget: the run's budget is set with the first task (`budget_usd`); spend is added from the
  worker's summaries as it arrives, and an assistant message that crosses the budget cancels the
  attempt (`cancelled by BM: budget`). The plan's example (budget 0.005, second attempt refused)
  was off: admission refuses only once confirmed spend has reached the budget.
- Time limits: `max_duration` and `stall_timeout` are coordinator options; a running tool is never
  a stall.
- Revert: `Coordinator.revert/1` reverts the run's latest attempt if it left changes (held,
  failed, cancelled, reconciliation or accepted); a reverted latest attempt means nothing is left
  to revert.
- Recovery runs at application start (off in tests) **and when a coordinator starts**, so a
  coordinator that died mid-attempt is recovered by its successor. It stops the orphaned pi
  adapter, ends the recorded groups of the current boot (pi's, bash commands', and the verify
  command's, now recorded on the attempt), and marks the attempt. An interrupted attempt holds the
  lane and the run stays paused until the user keeps or reverts it; then the run resumes.
- Coordinator jobs are now linked tasks: they die with the coordinator.

---

## Phase 6: run page and milestone B gate

**6.1 Start form.** Home page gets a form (`id="task-form"`): workspace path, task text,
declared files (optional), verify command (saved on the workspace). Submit calls `run_task` and
navigates to `/runs/:id`.
Verify: LiveView test submits the form with a temp repo and the fake pi and lands on the run page.

**6.2 Run page** (`BmWeb.RunLive`, `/runs/:id`). Header: goal, status, spend (confirmed +
"N unknown"). Attempts as a stream (`id="attempts"`): status badge, flags, worker summary,
verification output (collapsible), write set with per-file diff (`git diff <tree_before>
<tree_after> -- <path>`). Live updates via PubSub topic `run:<id>` broadcast by the coordinator.
Verify: LiveView tests with `has_element?` on `#attempts`, `#attempt-<id>-status`, `#diff-<id>`.

**6.3 Actions.** Buttons `#stop-btn` (cancel), `#keep-btn` and `#revert-btn` (shown only when the
lane is held), with loading states. Revert refusal shows the changed files.
Verify: LiveView tests click each button and assert the resulting status element.

**6.4 Milestone B gate (live).** `test/live/milestone_b_test.exs` in a scratch repo with a staged
user change, a dirty user file, and `verify_command: "sh check.sh"`:
1. Task "create hello.txt containing hi" → accepted, checkpoint ref exists, staged change and
   dirty file untouched.
2. Task "append a line to <dirty user file>" → denied by policy or failed by the write set; user
   file unchanged.
3. Task whose change breaks `check.sh` → held; Revert restores it.
4. Kill the coordinator mid-attempt and run `Recovery.run/0` → `needs_reconciliation`.
Verify: `mix test --only live` passes.

**6.5 Mini-benchmark.** `mix bm.bench` with 5 small tasks in a fixture repo: (a) plain `pi -p` in
a copy of the repo, then run the same check; (b) BM single worker. Record verified success, cost,
wall time and manual interventions in `docs/BENCHMARK.md`.
Verify: file exists with both columns. **Decision point:** continue to Phase 7 as planned,
or fix what the numbers show first.

**Status: Phase 6 done (2026-09-29); milestone B exit gate passed.**
- 6.1–6.3: Tasks page (`/`, task form and recent runs), run page (`/runs/:id`: attempts streamed
  live with status, worker summary, flags, verification output and per-file diffs; Stop, Keep,
  Revert, Revert last change, next task, Finish run). The coordinator broadcasts on the
  workspace topic (not `run:<id>`); `Coordinator.finish_run/1` was added so a run can end. The
  prototype chat moved to `/chat`, marked as not guarded by BM; `Layouts.app` is BM's shell.
- 6.4: `test/live/milestone_b_test.exs` passes with the real model (≈13 s): accepted +
  checkpoint; a task needing the user's dirty file fails without touching it; a failing
  verification holds and Revert removes the change; a killed coordinator's attempt is recovered
  as `needs_reconciliation` and its processes are ended. Finding: the model's first move was
  `printf ... >> notes.txt` through bash, which the policy did not check; the policy now refuses
  shell writes (redirects, `tee`, `sed -i`, `cp`/`mv`/`install`/`ln` destinations, `rm`) to the
  user's files, outside the workspace and in `.git`, and the worker then reports the task as
  blocked without writing.
- 6.5: `mix bm.bench` (docs/BENCHMARK.md): both modes verified 5/5 small tasks; BM cost $0.060
  and 25 s against $0.077 and 39 s for plain pi (one sample; plain pi carries the user's full
  setup). **Decision:** the tasks are too easy to separate the modes on success; BM's value at
  this size is the guarded, verified, recorded result, at no extra cost. Continue with Phase 7;
  the milestone C benchmark (8.3) must use multi-step goals and include tasks that touch the
  user's files, where the modes can differ.

---

## Phase 6.6: hardening before the planner

Added after a review of milestone B (2026-09-29). Each item either removes a known gap that the
planner would build on, or produces data that Phase 7's rules depend on. Do these before 7.1.

**6.6.1 See the UI.** Start the dev server, run one real task in a scratch repo through the Tasks
page, and walk the run page (attempts, diff, verification output, Stop / Keep / Revert / Finish)
in a browser. Fix layout and state bugs found. Nothing in Phase 6 was ever looked at.
Verify: screenshots of the Tasks page and of a run page with a held attempt attached to the
commit message or docs; the LiveView tests still pass.

**6.6.2 Remove the prototypes.** ~~Delete `ChatLive` (`/chat`), `FlowLive` and the Svelte Flow
assets.~~ **Reversed (2026-09-30) at the user's request:** the chat page with its agent canvas is
in use and stays. It keeps its "not guarded by BM" notice; the canvas can later show run data.

**6.6.3 Baseline verification.** At run start, after the baseline snapshot, run the workspace's
verify command once and store the result on the run (`baseline_verify`). The run page shows
"your checkout already fails verification" with the output when the exit is not 0. Attempts still
run; the user decides. Reason: verification runs on the shared checkout including the user's
uncommitted work, so a broken checkout would hold every attempt with a misleading message.
Verify: a scratch repo whose check fails before any task shows the warning; one that passes
does not.

**6.6.4 Harder single-task benchmark and write-set data (live).** Extend `mix bm.bench` with
three harder tasks: one that spans three files, one that needs a file the user has dirty (the
right outcome is `blocked`), and one that needs a generated file (a formatter or a build step
changes files that the worker did not name). Run each three times per mode. Record, per BM
attempt, the declared write set against the actual write set: exact, subset, superset, disjoint.
Verify: `docs/BENCHMARK.md` has the new table and a paragraph answering open question 7 (how
well the model declares write sets). **Decision point:** the answer sets the rule in 7.1: if the
model is mostly exact or a subset, keep `writes` required for mutating tasks; if not, make it
advisory (planner may omit it; the flag stays) and record the decision in ARCHITECTURE.md §2.

**6.6.5 Guarded read-only bash.** The planner and the reader need to run things (`git log`, the
test suite, a build) to plan and to analyse; today they have only `read`, `grep`, `find` and
`ls`. Give both profiles `bash` behind `bm_guard` with the policy in **read-only mode**
(`Bm.Policy.authorize/3` with `mode: :read_only`): every redirect target, every write command
(`tee`, `sed -i`, `cp`, `mv`, `rm`, `install`, `ln`, `mkdir`, `touch`, `chmod`) and every git
write is refused; unknown commands are allowed. The guarantee stays the same as for the reader
today: the policy is a safety net, and the snapshot after the session fails the attempt (or, for
the planner, holds the run) if any file changed. The profile check lists `bash` for both roles.
Verify: policy tests for read-only mode; a reader attempt whose fake pi runs `echo x > f` is
refused, and one that writes through an interpreter is failed by attribution with the file
listed; the live qualification suite passes with the new profiles.

**Status: 6.6.1–6.6.2 done (2026-09-29).** Screenshots in `docs/screenshots/` (Tasks and run
page, desktop and phone; headless Chrome with device emulation, since the desktop window can't go
below ~485 px). Fixed or added while looking: the run page never showed the task text (now a
"Task" fold with the declared files), attempts had no time, duration or checkpoint ref, recent
runs had no time or spend, a finished run was a dead end (now "New task here" prefills the
repository via `/?path=`), the repository field suggests known workspaces, the held-lane message
names the reason (verification failed / timed out / interrupted), the brand read "BEAM". No
horizontal overflow at 390 px. The chat and flow pages were removed here and restored on
2026-09-30 at the user's request (see 6.6.2). Follow-ups (2026-09-30): a failed or timed-out
verification opens unfolded on held and failed attempts; refusals of Stop / Keep / Revert /
Finish are explained in words instead of Elixir terms; the dotted meta lines no longer start a
wrapped line with a stray dot. `config/dev.exs` now honours `PORT`.

**Status: 6.6.3 and 6.6.5 done (2026-09-29).**
- 6.6.3: the first attempt of a run goes through a `:baseline` phase: the verify command runs
  once on the untouched checkout; its exit, output tail and the files it changed are stored as
  `runs.baseline_verify` and broadcast; the attempt's `tree_before` is re-taken afterwards so a
  generator's output is not attributed to the worker. Cancel during the baseline ends the command
  and the attempt. The run page warns when the baseline failed (fold with the output) and, in a
  separate note, when the verify command changed the user's own uncommitted files. Two existing
  tests had to make their generators non-idempotent, since the baseline now runs them first.
- 6.6.5: `Bm.Policy` has a read-only mode (`ctx.mode`): edit/write refused; bash refused when it
  redirects anywhere but a device or temp file, and for `tee`, `sed -i`, `cp`, `mv`, `rm`,
  `mkdir`, `touch`, `chmod`, `dd`, `patch`, `rsync`, `unzip`, `tar x` and git writes; anything
  else runs. Planner and reader profiles carry `bm_guard` and `bash`; the coordinator picks the
  mode from the attempt's role; `Bm.Bridge` lets planners send `authorize`. Live qualification
  4/4 with the new profiles (the reader tried a shell redirect and was refused). `mix precommit`
  160 tests.

**Status: 6.6.4 done (2026-09-29); Phase 6.6 complete.** `mix bm.bench` now runs five easy
tasks once and three hard ones (`stats`: three files; `dirty`: the task needs a file the user
has uncommitted changes in; `sub`: the verify command regenerates `api.md`) three times per
mode, and for every BM run a planner-profile pi first declares the write set (`propose_task`),
which becomes the task's `writes`. Results (docs/BENCHMARK.md, 28 runs, ≈$0.40):
- **Write sets (open question 7): exact in 11 of 11 runs that changed files**, including the
  three-file task and `api.md` for `sub` (the planner read `gen.py` and declared the generated
  file; the worker then ran the generator itself, so the verify-changed-files path was not
  exercised by the model). The three `dirty` runs declared `text.py` and changed nothing.
  **Decision for 7.1: keep `writes` required and non-empty for mutating tasks**; an undeclared
  write stays a flag, not a failure.
- **The user's file:** plain pi overwrote the user's uncommitted `text.py` in 3 of 3 runs; BM
  refused in 3 of 3, the worker reported `blocked` and the file was intact. This is the
  difference the benchmark was meant to show.
- **Success:** BM 11/14 (the three misses are the intended `dirty` refusals), plain pi 13/14
  (one `fix_add` run failed its check). Cost BM $0.22 vs $0.18, wall time 139 s vs 111 s: the
  planner declaration and the guarded start cost about a fifth more. Acceptable for the core;
  warm reuse stays optional.
- Recovery gap found on review: a verify command started in the baseline phase was not
  recorded on the attempt; it now is (`verify.baseline = true`), like the attempt's own.

---

## Phase 7: planner (fake pi)

Revised 2026-09-29 (see the Phase 6.6 introduction). The planner is **its own process**
(`Bm.Workspace.Planner`, one per run, under `Bm.Workspace.Supervisor`), not part of the
coordinator: the coordinator keeps owning the lane and the attempt state machine, and the planner
process owns the planner pi session, plan validation calls, the task graph and result delivery.
They talk by messages; the coordinator never calls the model. Reason: the coordinator is already
1,000 lines with one state machine, and a second one inside it would not be testable on its own.

**7.1 Plan validation (pure).** `Bm.Plan.validate(proposal, ctx)` with `ctx = %{tasks,
user_owned, root, budget_left, plan_open}`: required fields; `key` format and unique in the run;
`depends_on` refers to existing keys; no cycles; `writes` inside the root and not user-owned;
`writes` required and non-empty when `mutates` (confirmed by 6.6.4: exact in 11/11); optional
`check` (a shell command, see 7.7) is a non-empty string; plan must be open.
Returns `{:ok, task_attrs}` or `{:error, reason}` with a reason the model can act on.
Verify: table-driven tests for each rule, including a three-task cycle.

**7.2 Fake planner.** `fake_pi.mjs` gains `plan:<json>`: sends one `bm:propose_task` dialog per
listed task, then `bm:close_plan`; on each `follow_up` it can run the next scripted wave. It can
also be told to propose the same invalid task N times, to test 7.8.
Verify: `pi_test.exs` sees the dialogs in order.

**7.3 Planner process.** `Bm.Runs.start_goal(path, goal, opts)` starts the run with
`plan_open = true` and starts `Bm.Workspace.Planner` for it. The planner process starts pi
(`Profile.start(…, :planner)`, owner = the planner process), takes a snapshot before the session,
and prompts it with `Bm.Prompts.planner(goal, workspace)`. `propose_task` → validate → insert
task (`queued`) → reply `accepted` or `rejected` with the reason; `close_plan` →
`plan_open = false`. The planner's usage events count against the run's budget exactly like an
attempt's (`spent_usd`, `spent_unknown`); the cap stops the planner too. When the planner
session ends, a snapshot after it is compared with the one before: any change holds the run
(`needs_reconciliation` on the run, shown to the user) — the planner writes no code.
Verify: a scripted plan with one invalid task yields two queued tasks and one rejection reply;
streamed `propose_task` events alone (without the dialog) create no task; a fake planner that
reports usage moves the run's spend; a fake planner that writes a file leaves the run held.

**7.4 Sequential scheduler.** Lives in the planner process. After every lane change (the
coordinator broadcasts them) pick the oldest `queued` task whose dependencies are `accepted` and
ask the coordinator to admit it (Phase 4 `run_task` with an existing task). Read-only tasks run
in the same lane with the reader profile. Tasks whose dependency failed become `blocked`.
Verify: tasks `a`, `b(depends a)`, `c` run as `a, b, c` or `a, c, b`, never `b` first; failing `a`
blocks `b`.

**7.5 Dependency context for workers.** `Bm.Prompts.worker/2` takes the task and its accepted
dependencies: for each, the title, the worker's summary and the actual write set of the accepted
attempt (paths only). The worker still never sees the plan or the conversation. Reason: a task
that depends on another must know what that one changed; nothing tells it today.
Verify: prompt test with two dependencies; a task without dependencies gets the Phase 4 prompt.

**7.6 Result delivery.** When an attempt ends, record a delivery (received), then send the planner
one `follow_up` per batch of finished tasks at its next idle point (delivered). The message
carries each task's status, summary, flags and, for a held or failed attempt, the verification
tail. The planner may propose more tasks (it must reopen: `propose_task` while closed is rejected
unless the delivery reopened planning) and must `close_plan` again. One automatic re-plan per
failed task; then the run fails.
Verify: two tasks finishing while the planner is busy produce one `follow_up`; a duplicate
`submit_result` produces one delivery; a failed task leads to exactly one re-plan message.

**7.7 Task check.** A task may carry a `check` command (the planner's executable form of
`done_when`, e.g. `pytest tests/test_cli.py -q`). After the workspace verify command passes, the
coordinator runs the task's check the same way (own process group, timeout, output tail) and the
attempt is accepted only if both pass; a failing check holds the lane like a failing verify, with
the check's output. Reason: the workspace verify proves the checkout still works, not that the
task did what it was asked; with several tasks in a run the difference matters.
Verify: fake-pi test where the verify passes and the check fails → held with the check output;
both pass → accepted; no check → unchanged behaviour.

**7.8 Runaway planners.** More than `max_rejections` (default 5) rejected proposals in one plan
wave, or more than `max_waves` (default 4) waves in a run, fails the run with a message naming
the limit. A planner idle with the plan open for `plan_timeout` (default 5 min) fails the run.
Verify: tests for each limit; the run ends `failed` and the workspace lock is released.

**7.9 Run completion and planner recovery.** A run is `done` when the plan is closed and every
task is terminal (`accepted | failed | blocked | cancelled`); `failed` if any required task
failed. Recovery (`Bm.Workspace.Recovery`) also covers the planner: after a BEAM restart, a run
with `plan_open = true`, or with queued tasks and no planner process, is **paused** with the
reason "planner lost", its planner pi is stopped through the recorded process groups, and the
run page offers "Resume planning" (start a new planner session with the goal, the accepted tasks
and their summaries) or "Finish". No automatic restart of the planner.
Verify: tests for done, failed and paused-by-recovery; resume produces a planner prompt that
lists the accepted tasks; the workspace lock is released each time a run ends.

**Status: Phase 7 done (2026-09-30).** 7.1 and 7.2 have their tests (validation table, scripted
fake planner). For 7.3–7.9 the user asked for no new tests; they were verified with the existing
suite (199 tests) and a live goal run with the real model (below).
- 7.3: `Bm.Workspace.Planner`, one per goal run, started by `Coordinator.start_goal/3`
  (run created with planning open and a `planner` map). It answers `propose_task` (validated,
  stored as a queued task), `close_plan` and read-only `authorize`, adds its spend to the run and
  aborts on an exhausted budget, and compares snapshots before and after each turn: a planner
  that changed files pauses the run. **Decision (D20 note):** planner turns happen only while
  the lane is free and tasks are admitted only while the planner is idle, so planner and worker
  never run at once and each snapshot diff belongs to exactly one of them.
- 7.4: scheduling in the planner; the coordinator admits an existing queued task
  (`run_task(path, %{task_id: id})`, refused for another run). Blocked = a dependency's latest
  revision failed, was blocked or cancelled.
- 7.5: `Bm.Prompts.worker/2` gets `Runs.dependency_context/1` (title, summary, files changed).
- 7.6: deliveries table (unique per task revision); failures are delivered at once, accepted
  results in one batch when nothing else can run; each delivery reopens planning (a wave).
  A re-plan is the same key proposed again (revision 2, once); a second failure fails the run.
- 7.7: `tasks.check` runs after a passing verify command; a failing check holds the lane
  (`check_failed` / `check_timeout`), its output is in `verify.check`. Found in the final review:
  `bm_planner.ts` had no `check` parameter, so the real model could not set one; added. Live:
  a goal asking for checks produced 2 tasks, each with a check that ran after verification and
  passed (`verify.check.exit == 0`), run done ($0.05).
- 7.8: `max_rejections` (5 per wave), `max_waves` (5), a reminder then `plan_timeout` (5 min)
  for an idle open plan, `turn_timeout` (15 min).
- 7.9: done when the plan is closed and every latest task is accepted (failed otherwise);
  `Coordinator.end_run/4` cancels queued tasks; recovery pauses goal runs whose planner is gone
  ("planner lost", groups ended on the same boot), the coordinator pauses the run if the planner
  process dies, and `Coordinator.resume_planning/3` starts a new session with a resume prompt.
  Finishing a goal run by hand stops its planner: done only if the plan is closed and all
  tasks were accepted, cancelled otherwise.
- Live check (scratch script, real model): goal "shapes.py + area.py CLI + test_shapes.py" →
  3 tasks (two depending on the first), all accepted and checkpointed, 2 waves, run done in 25 s
  for $0.063, the user's dirty file intact. Noted: without a `.gitignore`, the verify command's
  `__pycache__` files are attributed to the attempts (flagged, harmless).

---

## Phase 8: plan UI and milestone C gate

**8.1 Run page with plan.** Goal form on the home page (`#goal-form`); on the run page a planner
panel (transcript, `#planner`) and a task list stream (`#tasks`) with key, title, dependencies,
state and the latest attempt linked.
Verify: LiveView tests for both elements and a task state update arriving over PubSub.

**8.2 Milestone C gate (live).** A goal in a scratch repo that needs 2–3 dependent tasks.
Also a fake-pi test in the same file: a cancelled planner stream (`abort` mid-stream) creates no
task and no write.
Verify: run `done`, one checkpoint per mutating task, user files untouched.

**8.3 Benchmark.** Extend `mix bm.bench` with 3 multi-step goals, each with dependent tasks and at
least one touching a user-owned file: plain pi vs BM planner, three runs each. Record in
`docs/BENCHMARK.md` (verified success, cost, wall time, decisions left to the user, planner share
of the cost) and decide which optional feature to build first (see FEATURES.md preconditions).
Verify: results recorded; FEATURES.md updated with the decision.

**8.4 Milestone C review.** Before merging to `main`: re-read Planner, the scheduler and delivery
for real bugs as in earlier phases, probe recovery with a killed planner, and update
ARCHITECTURE.md §13 (verified facts) and §16 (code map).
Verify: findings fixed and listed in the Status note.

**Status: Phase 8 done (2026-09-30); milestone C exit gate passed (live).** At the user's request
no new test files were written in this phase; the existing suite (199 tests) passes, and the
gate ran as live scenarios from a scratch script with the real model.
- 8.1: Tasks page has Goal / Single task modes (`#goal-form`, `#task-form`); the run page of a
  goal run shows the planner (`#planner`: phase, wave, plan open/closed, summary, log with the
  planner's replies as markdown), the task list (`#tasks`, live), the run's reason
  (`#run-reason`), and Resume planning / Finish when paused. Checked in a browser on desktop and
  phone with a goal submitted through the form (run done, 2 tasks, $0.04);
  screenshots `docs/screenshots/goal-run*.png`.
- 8.2 gate (live): **A** finishing a run while the planner is still thinking ends it cancelled
  with no task, no attempt, no file change and the planner gone; **B** killing the planner after
  the first accepted task pauses the run ("the planner stopped unexpectedly"), Resume planning
  starts session 2 with the tasks so far, and the run ends done: 3 tasks, 3 checkpoints, the
  goal's check passes, the user's staged change and dirty file intact, HEAD untouched. Earlier
  live runs: 3-task goal done in 25 s ($0.063), 2-task goal via the UI done in 20 s ($0.04).
  The fake-pi "abort mid-stream" test of the plan was not written (no new tests); scenario A
  covers the cancelled-planner case live.
- 8.3 benchmark (`mix bm.bench --goals`, docs/BENCHMARK_GOALS.md, 18 runs): both modes pass the
  goals' checks 9/9; plain pi $0.12 / 68 s, BM planner $0.60 / 356 s (about 5× on these small
  goals: planner turns, a fresh pi per task, the verify command after every task). Plain pi
  changed the user's uncommitted `text.py` in 3/3 runs, BM in 0/3: its planner put the word
  counting into `wc.py` instead. The goal's check tests only `wc.py`, so for BM "verified" there
  means the observable goal works while the part that needs the user's file was not done.
  **Decision:** parallel read-only workers are *not* next (the time is not planner-side
  reading); the next optional work is cutting per-goal overhead: warm worker reuse (start-up per
  task) and ending a run without a final "all done" planner turn when the plan is closed and
  every task was accepted (each benchmark run spent its second wave on it).
- After the review: `mix test --only live` (qualification 4/4 + milestone B gate) passes
  against the current coordinator.
- 8.4 review, fixed: an idle planner never noticed a coordinator that had died (it now re-checks
  every 5 s and restarts the coordinator); with the budget spent and the plan open, the
  scheduler could still send a paid reminder turn (it now ends the run); a single task started
  from the Tasks page while a goal run was active would have joined that run behind the
  planner's back (now refused: "A planner run is active in this workspace").

---

## Phase 9 (optional): goal-run overhead

Chosen by the 8.3 decision (BM planner ≈5× plain pi in cost and time on small goals).

**9.0 Measure first.** A scratch profile of one live goal run (planner turn intervals from its
log, attempt phase transitions, spend attributed to planner or workers, which is exact because
they alternate, D21): worker start-up (admitted → running) is **0.3–0.45 s per task**, ≈1 s of a
22–28 s run, so **warm worker reuse is dropped**. The planner was the cost: its first turn took
7–13 s and ≈60 % of the spend, made of one model round-trip per action (list files, read files,
one per proposed task, close_plan), plus a final turn that only said "all done" (≈2.5 s).

**9.1 No final planner turn after a clean plan** (D22). When the plan is closed and every pending
result is accepted without flags, the run completes; the planner log gets a note saying why.
The planner prompt now says BM comes back only on failures, blocked tasks or surprises.

**9.2 `propose_plan`.** One call with every task in dependency order, validated in order in one
transaction (a task may depend on an earlier one in the list), reply per task, rejections counted
per task, optional `close_summary` that closes the plan only if every task was accepted.
`propose_task` stays for adding or re-proposing one task. Profile, bridge and the two existing
tool-list assertions updated.

**9.3 File list in the first planner prompt** (`git ls-files --cached --others
--exclude-standard`, at most 150 paths), which removes the `ls` round-trip.

**9.4 Benchmark before/after.** `mix bm.bench --goals`, compared with the Phase 8 numbers.

**Status: Phase 9 done (2026-09-30), benchmark partial.** 9.1–9.3 implemented; `mix precommit`
passed and `mix test --only live` passed 5/5 after 9.2. The 9.4 benchmark was **stopped by the
user after 13 of 18 runs** (no more benchmarks or tests were to be run), so `BENCHMARK_GOALS.md`
still holds the Phase 8 numbers. Finished runs, same goals as Phase 8:

| Goals (3 runs each) | Phase 8 BM | Phase 9 BM | Plain pi (Phase 9 runs) |
|---|---|---|---|
| shapes + calc_cli: verified | 6 / 6 | 6 / 6 | 5 / 6 |
| wall time (6 runs) | 150 s | 118 s (−21 %) | 41 s |
| cost (6 runs) | $0.255 | $0.196 (−23 %) | $0.072 |
| planner waves per run | 2 | 1 | – |

BM is now ≈2.9× plain pi in time and ≈2.7× in cost on these goals (was ≈3.6× and ≈3.1×).
One live profile after 9.1–9.3: planner round-trips 8 → 2, planner cost ≈$0.02–0.03 → $0.013.

**Finding from the stopped benchmark (`text_tools` #1):** the planner wrote a task `check` with
JSON-escaped quotes (`[ \"$(...)\" = \"3 12\" ]`) and a wrong expected value ("3 12"; the text
has 13 non-space characters). The check could never pass, the attempt was held for the user,
and the unattended benchmark waited 17 minutes ($0.17) until its timeout. The worker had even
bent its code toward the wrong value. Fixed without running anything: `Bm.Plan` rejects checks
containing `\"`; the planner prompt says a failing check stops the run until the user decides, so
checks must be plain shell, preferably a test the task adds, never an uncomputed hard-coded
value; `mix bm.bench --goals` stops waiting when an attempt is held (counted as a decision).
These three fixes are compiled but **not verified by a test or a live run** (at the user's
request). Open: a wrong planner check still holds the lane; delivering a failed *check* to the
planner (instead of holding) would let it correct its own check, but changes the "failed
verification waits for the user" rule and needs a decision first.

---

## Phase 10 (optional): seeing a run

Chosen 2026-09-30 from FEATURES.md (usability); the user asked for no tests, so each step was
checked by compiling (`--warnings-as-errors`), in the browser, or by hand.

**10.1 Run canvas.** A goal run's page shows a Svelte Flow canvas (`#run-canvas`, the chat
page's `FlowCanvas` hook): the planner (the chat page's agent node, with side handles), one
`TaskNode` per task key, edges from dependencies (from the planner for tasks without any),
laid out left to right by dependency depth (`BmWeb.RunGraph`). It redraws on task, attempt and
run events, keeps nodes the user dragged, and refits when nodes are added. A paused or ended
run's planner shows Paused / Finished whatever its last pi event said.

**10.2 Live worker activity.** The run page subscribes to the planner's and the running
worker's pi sessions. The running task's node and the action bar show the tool running now, or
the last one while the model thinks, the number of tool calls, and tokens. (Tools often run for
milliseconds, so "last" is what one mostly sees.) The planner now broadcasts the end of its
turns, so the panel says "waiting while tasks run" instead of "thinking".

**10.3 Checkpoint pruning.** When a run ends, the coordinator keeps the checkpoint refs of the
workspace's newest runs (workspace setting `keep_checkpoint_runs`, default 20) and deletes
older runs' `refs/bm/runs/<id>/*` in one `update-ref --stdin` transaction, in the background.
Runs never share checkpoint commits, so kept runs are unaffected. A pruned run's page says so.

**Status: done (2026-09-30).** Checked live: two small goal runs through the form (runs 46 and
47, ≈$0.03 each) showed the canvas refitting as tasks appeared, the running task glowing with
"Last: submit_result …, 3 tool calls" and tokens, and a finished planner as Finished
(`docs/screenshots/goal-run-canvas.png`). Pruning was checked by hand on a throwaway repository
(only the chosen run's refs deleted, branches untouched); the automatic trigger after a run ends
was not seen live (it needs more than 20 runs in one workspace). Known cosmetic gap: an edge that
skips a column can run behind the node in between.

**10.4 Attempt transcripts.** When a worker's pi session stops (every path goes through the
coordinator's stop job), its transcript is read first and stored compacted on the attempt
(`attempts.transcript`: tool calls with name, detail and outcome, the worker's messages up to
1,500 characters, errors and notices; at most 300 entries; the prompt is left out, it is the
task). The attempt card has an Activity fold ("4 tool calls, 1 failed"). Checked live (run 48):
read, edit, bash (the check), submit_result, all ✓.

**10.5 Run history and search.** The Tasks page's run list (`#run-search`) filters by text in the
goal or the repository path (case-insensitive, `%` and `_` escaped) and by status, 20 at a time
with Show more (`Runs.search_runs/3`). Checked in the browser: "greet" + Done lists the four
matching runs.

**10.6 Failed task checks go back to the planner (D23).** Decided 2026-09-30 (the user asked for
the best decision; a reviewer agreed). `Coordinator.verified_outcome/3`: in a goal run, verify
passed + check failed/timed out → the attempt finishes `failed` with an actionable error ("the
task's check `…` exited 1"), then `Git.restore` puts its files back if they still hold what it
left, and it becomes `reverted` with flag `auto_reverted`, the lane free; otherwise it stays held.
The task stays `failed`, so the planner is told "failed" (not "cancelled"), with the check command
and its output, and that the files are back as before. Single-task runs and the user's verify
command are unchanged. The planner prompt no longer says a failing check stops the run. The run
page labels "passed; task check failed (exit 1)", shows the check's command and output, and opens
that fold. Incidental fix: a re-planned task whose check failed again used to hold the lane, so
the "failed again after its re-plan" rule could never end the run; now it does.
Checked with a throwaway scratch script on the scripted fake pi (no model, no test file; the fake
now also runs its next planner wave on a prompt, as the planner sends results as prompts):
check `exit 1` → attempt reverted + `auto_reverted`, file gone, lane free, delivery `failed`,
planner told to re-plan, run failed when it closed; re-proposed with `exit 2` → revision 2
reverted too and the run failed "task make_out failed again after its re-plan". Not seen with the
real model.

---

## Consolidation (2026-09-30)

Before merging `core-milestone-b` (phases 0–10, D1–D23) into `main`, at the user's request:
- `mix test`: **199 passed**, 6 excluded. Nothing broke in phases 9–10.
- `mix test --only live`: **5 passed** (qualification 4/4 with the current profiles, milestone B
  gate against the current coordinator: stop job with transcripts, D23 branch).
- Checked by hand (scratch scripts, fake pi, no model, no test files): a planner check with
  escaped quotes is rejected with an actionable reason and plain shell is accepted; automatic
  pruning after a run (`keep_checkpoint_runs` = 1): after the second run finished, only its refs
  remained, branches untouched.
- Still not seen live: D23 with the real model (only the scripted planner), the planner prompt's
  new check guidance in effect, and `mix bm.bench --goals` stopping on a held attempt (read
  through; no more benchmarks were to be run).

---

## Phase 11: real repositories

Scoped 2026-09-30 after merging phases 0–10 into `main` (branch `phase-11`). Every run so far
used tiny scratch Python projects; this phase uses BM on real code and adds the two safety
features real multi-task runs need. Per the user's standing instruction, no tests are written or
run; each step is checked by compiling, in the browser, and with small live runs. Trial runs cost
model money: an estimated $0.10–0.50 per goal on this repository.

**11.1 Trial setup.** The target is a **clone** of a real repository in a scratch directory,
never the checkout the dev server runs from (BM changing its own running code would be reloaded
mid-run). Default target: this repository (124 files, under the planner's 150-path list; a
snapshot takes 30–70 ms), verify command `mix compile --warnings-as-errors`, a budget per goal,
with a dirty file left in the clone to exercise user-owned files. A project of the user's can
replace it.

**11.2 Supervised trial goals.** Two or three goals of real size, started from the Tasks page and
watched on the run page, e.g. "add a `mix bm.runs` task that lists recent runs with status and
spend" (3 files, one new module) and "show the run's short label BM-<id> in the run header and the
runs list" (touches LiveViews and a component). Record in `docs/TRIALS.md` per goal: tasks
proposed, waves, attempts accepted/held/failed, time, cost, checks written, flags, and every
problem seen (wrong plan, wrong write set, stuck worker, confusing UI, anything unsafe).

**11.3 Fix what the trial shows.** Scope decided by 11.2. Each finding is fixed or recorded as a
decision; safety problems first.

**11.4 Revert a whole run.** Today only the latest attempt can be reverted; undoing a four-task
goal means reverting by hand. Design: one conditional restore over the union of the write sets
of the run's accepted (non-reverted) attempts, from the earliest such attempt's `tree_before` to
the latest one's `tree_after`, with `Git.restore/5` (all or nothing; refused with the changed
paths if any file changed since). Allowed only while the workspace's lane is free and no newer
run touched those files (the condition covers it). The run keeps its status and records
`reverted_at` (migration); its attempts become `reverted`; checkpoints stay as the record. Run
page: "Revert this run" on finished runs, with the refusal listing changed files.

**11.5 Refined limits.** (a) **Repeat-call guard:** the coordinator counts identical guarded tool
calls (tool + input) per attempt; the 4th identical call is refused with a reason and the 6th
cancels the attempt ("repeating itself"). (b) **Tool timeout:** a single tool call running longer
than `tool_timeout` (default 10 min) cancels the attempt; today the stall limit applies only
between tools and `max_duration` (20 min) is the only bound on a hung command. (c) **Soft budget:**
at 80 % of a run's budget the run page shows a warning, and the planner is told in its next turn
to finish with the smallest plan.

**Optional, if time allows:** short labels (`BM-<id>`) everywhere a run is named; `ask_planner`
for workers; a question-sharpening step before planning built on the chat page.

**Open before 11.2:** the user may name the repository, goals and verify command; otherwise the
defaults above are used.

**Status 11.1–11.3 (2026-09-30).** Trial clone set up; three goals run through the UI (runs 54–57,
docs/TRIALS.md): two real features built and accepted ($0.09 and $0.16, 19 s and 69 s), the
user's dirty README never touched. One real problem found and fixed: a goal BM had to refuse ended
"done"; a task-less plan after rejected proposals now ends failed with the planner's summary
(checked live, run 57). Noted: planner checks ran the clone's own tests, which share the test
database with this checkout.

**Status 11.4 (2026-09-30).** `Coordinator.revert_run/2`: one `Git.restore` over the union of
the write sets of the run's attempts whose changes stayed (accepted, or kept by the user), from
the earliest one's `tree_before` to the latest one's `tree_after`; refused while the workspace has
an unfinished run or an attempt runs, for unfinished or already reverted runs, and with
`changed_since` (nothing touched) when a file changed after the run. Those attempts become
`reverted`, the run records `reverted_at`, checkpoints stay. Run page: "Revert this run" (with a
confirmation) on finished runs; the finished note says when it was reverted. Checked on the trial
clone through the UI: reverting run 55 put its 4 files back (run 54's file and the user's README
untouched); run 54 with a hand edit in its file was refused ("lib/mix/tasks/bm.runs.ex changed
since the run. Nothing was touched.") and the edit survived; after undoing the edit, reverting run
54 deleted the file it had added; the clone was back to the user's README change only.

**Status 11.5 (2026-09-30); Phase 11 done.** Coordinator limits: identical guarded tool calls
(same tool and input) are counted per attempt; the 4th is refused with a reason the model can act
on ("You have made this exact bash call 4 times; repeating it will not help…"), the 6th cancels
the attempt ("repeating the same call"); one tool call running longer than `tool_timeout`
(10 min) cancels it ("tool_timeout"; before, only `max_duration` bounded a hung command). All
three are coordinator options. Soft budget: an unfinished run past 80 % of its budget shows
"N % of the budget used" in the run header, and the planner's next delivery asks it to finish
with the smallest plan. Checked with a scratch script on the fake pi: 4th identical call refused;
with `repeat_cancel: 3` the attempt was cancelled; with `tool_timeout: 1_000` a `sleep 5` was
cancelled. The soft-budget warning and note were read through, not seen live.

---

## Phase 12: better plans, fewer failures

Scoped 2026-09-30 after merging Phase 11 (branch `phase-12`). The trial showed safety holding;
the weak spots are how well a goal is understood and what a worker does with an unclear task.
No tests written or run (user's instruction); checked by compiling, the browser, scratch
scripts on the fake pi and small live runs.

**12.1 Run labels.** `BmWeb.RunComponents.label/1` → `BM-<id>`; used in the run header, the run
page title and the Tasks page runs list.

**12.2 `ask_planner` for workers (D24).** A worker whose task is genuinely ambiguous asks the
planner one specific question and waits for the answer. The worker is blocked inside that tool
call, so the planner may take a short **answer turn** while the attempt runs: an exception to D21.
No snapshot check on answer turns (anything written in that window is attributed to the attempt,
whose own snapshots and verification cover it; the planner still can't write, read-only policy);
the planner may not propose tasks or close the plan in an answer turn. Bridge split into
`check/3` (role, fencing, duplicates) and `record/5` (persist) so a model turn never holds a
transaction; the coordinator asks asynchronously (`state.asks`), answers with a fallback if the
planner is unavailable, times out (3 min) below the tool timeout, and still answers the dialog if
the attempt ends meanwhile. Single-task runs answer "no planner; decide yourself or report
blocked". Planner log kinds `question`/`answer`; run page phase "answering a worker".

**12.3 Goal review.** In the Goal form, "Review goal" asks a read-only planner-profile session
(read-only bash answered by the policy) for clarifying questions and a sharper goal; the user
answers inline and applies the suggested goal before starting. Not on the chat page (that runs
the user's own unguarded pi).

**Not in this phase:** a trial on a project of the user's (needs the repository and its verify
command from the user).

**Status 12.1–12.2 (2026-09-30).** Labels in place (run header, title, runs list). `ask_planner`
built as scoped (D24): `Bridge.check/4` + `record/5`; the coordinator asks asynchronously
(`state.asks`, fallback "planner not available…", 3 min) and answers the dialog even if the
attempt ended; the planner's `:answering` phase replies from its turn without a snapshot check or
scheduling and refuses proposals meanwhile; worker prompt says when to ask; profiles require the
tool (existing tool-list expectations kept in sync). Checked with a scratch script on the fake pi:
the worker's question was recorded with the planner's answer, the log shows "Worker asked" /
"Planner answered", the run ended done. Live on the trial clone (run 62, an ambiguous goal): real
workers started with the new tool (profile check passed), but **no worker asked**; the planner had
resolved the ambiguity in its plan. The question path is so far seen only with the fake pi.
Found on the way (dev only): the dev server's long-lived coordinator for the clone had been
started before the coordinator's state gained new keys; hot code reloading kept its old state and
the next attempt crashed (`KeyError :repeats`), taking the planner with it. Restarting the server
fixed it, and the restart exercised recovery on a real run: the attempt became "interrupted (no
changes; safe to run again)", run 62 paused "planner lost"; Resume planning started session 2,
which re-proposed the interrupted task, and the run ended done (2 tasks, $0.27). Rule: restart
the dev server after changing the coordinator's or planner's state.

**Status 12.3 (2026-09-30); Phase 12 done.** `Bm.GoalReview.review/2`: a planner-profile pi
session owned by the caller (the LiveView's async task), its read-only bash answered by the policy,
proposals refused; it returns up to 4 questions and a goal rewritten in at most 6 sentences
(files and checks, no line numbers), parsed from a JSON reply. Tasks page: "Review goal" beside
Start planning; the panel shows the suggested goal and the questions with answer fields; "Use
suggested goal" puts it in the goal field with the answered questions under "Clarifications:";
"Keep my goal" closes it. Checked in the browser on the trial clone ("make the runs list nicer",
$0.04 per review; `docs/screenshots/goal-review.png`): four relevant questions, a concrete goal,
and the applied goal ended with the answered question. Not done in this phase: a trial on a
project of the user's (needs the repository and verify command).

---

## Phase 13: safety during long runs

Scoped 2026-09-30 after merging Phase 12 (branch `phase-13`). Found while assessing: the
user-owned files were only those dirty at run start, so a file the user began editing during a
run could be overwritten by a later task. No tests (user's instruction); checked with scratch
scripts on the fake pi and the browser.

**13.1 Protect files edited during a run.** At each admission the coordinator diffs the state BM
last left against the new `tree_before`; changed paths join `baseline.user_owned` (and
`baseline.changed_during_run`), so the policy and the planner's validation refuse them. Checked
(fake pi): task 1 accepted, README.md edited by hand, task 2's write to README.md refused ("has
uncommitted changes of the user"), the hand edit intact, README.md listed as protected.

**13.2 Freshness check on write.** pi's `edit` re-reads the file and fails if the edited text
changed, so the clobbering risk is `write` (whole file). A worker's `write` to an existing file
that differs from the attempt's `tree_before` is refused unless this attempt already edited or
wrote that path, or ran a bash command (then BM can't tell who changed it; the snapshot still
attributes it).

**13.3 Undo one task.** On a finished run (or a run without a planner whose lane is free), an
accepted task's attempt can be reverted alone: conditional `Git.restore` of its write set from its
`tree_before`, refused if a later task changed those files (they no longer match its
`tree_after`) or if an accepted task depends on it.

**Status 13.2 (2026-09-30).** `Coordinator.freshness/3` in the authorize path, `Git.changed_since?/3`;
per attempt `touched` (paths allowed for edit/write) and `bash_ran?`. Checked (fake pi): README.md
edited while the worker was busy → its `write` refused ("README.md changed since your task
started, and not by you…"), the concurrent edit intact; a worker writing its own a.txt twice →
allowed, accepted.

**Status 13.3 (2026-09-30); Phase 13 done.** `Coordinator.revert_task/2` (finished runs only: in
an active run, BM's own undo would look like an outside change to 13.1 at the next admission).
Attempt cards of finished, not-reverted runs have "Undo this task" (with a confirmation).
Checked in the browser on the trial clone, run 62: undoing `shared_money_helper` was refused
("use_money_everywhere depends on this task. Undo it first."); undoing `use_money_everywhere`
restored its two files; then undoing `shared_money_helper` restored `lib/bm.ex` and deleted the
test file it added; the clone was back to the user's README edit only.

---

## Phase 14: quality gate and terminal use

Scoped 2026-09-30 after merging Phase 13 (branch `phase-14`). No tests (user's instruction).

**14.1 Reviewer (D25).** `Bm.Review.run/4` owns a reader-profile session (read-only bash via
the policy, its `ask_planner` answered with "decide from the task and the diff"), prompted with
`Bm.Prompts.reviewer/3` (task, done_when, check, dependency context, the diff capped at 20k
characters; reject only for concrete problems; don't rerun the tests). Coordinator: a passing
verification in a goal run goes to phase `:reviewing` (job `:review`); approve → checkpoint;
reject → D23 path with "the reviewer rejected the change: …"; reviewer failure → accepted with
flag `not_reviewed`; cancel stops the reviewer's session. The verdict, reason and cost are in
`attempt.verify["review"]`, the cost is added to the run. Run page: "review approved/rejected"
next to the verification label, the reviewer's reason in the fold. Checked: fake pi approve →
accepted with the review recorded; reject → auto-reverted, file gone, planner told, run failed
when it closed. Live on the trial clone (run 68, "Bm.Runs.count_runs/0"): the reviewer approved
with a specific reason ($0.027); run done.
Found again: the dev server's long-lived coordinator crashed on a state key added later
(`:touched`). Fixed for good: before admitting work the coordinator merges any missing
late-added state fields.

**Status 14.2–14.3 (2026-09-30); Phase 14 done.** Local JSON API (`BmWeb.Api.RunController`,
pipeline `:local_api` with `BmWeb.Plugs.LocalOnly`: requests from other machines get 403, since
production binds every interface): `POST /api/goals` (through `Coordinator.start_goal/3`, errors
worded like the Tasks page), `GET /api/runs` (`q`, `limit`), `GET /api/runs/:id` (also `BM-<id>`).
Terminal client (`Bm.CLI`, `mix bm.goal`, `mix bm.runs`, `mix bm.status`) talks to the running
server only (`BM_URL` or `PORT`, default 4001) and never starts BM itself. Checked against the dev
server: `mix bm.runs` and `mix bm.status BM-68` print the runs and the run's tasks with the review
verdict; `mix bm.goal … --repo /tmp/bm-trial` started BM-69, printed its URL (the web page showed
it live) and followed it to the end.
Found with the client: BM-69's goal needed `lib/bm/runs.ex`, which held run 68's accepted change,
uncommitted (BM never commits, so earlier runs' changes are the user's uncommitted work to the
next run); the planner proposed nothing and explained why, but the run ended "done: the planner
found nothing to do". Fixed: `close_plan` has an optional `blocked` flag (the planner prompt says
when to use it); a task-less plan ends failed if the planner marked it blocked or had proposals
rejected. Checked: the same goal again (BM-70) ended "failed: the planner could not plan the goal:
Blocked: … lib/bm/runs.ex … contains the user's uncommitted work".

---

## Phase 15: daily use

Scoped 2026-09-30 (branch `phase-15`) from the trial finding that BM never commits, so accepted
changes block the next goal that touches the same files.

**15.1 Commit a run's changes on request (D26).** `Git.commit_paths/3`, `Coordinator.commit_run/2`,
`runs.commit_sha`; run page "Commit these changes" (confirmed) on finished runs, then a note with
the short sha (Commit/Revert/Undo hidden once committed); `POST /api/runs/:id/commit`;
`mix bm.commit BM-<id>`. Subject = the goal's first line cut at a word boundary (72 characters).
Checked on the trial clone with run 68 via `mix bm.commit`: a hand edit in one of the run's files
→ refused ("lib/bm/runs.ex changed since the run…"); a run file staged by hand → refused ("you
have staged changes in test/bm/runs_test.exs…"); then with an unrelated file staged and the
user's README edit in place → committed c06358e7 with exactly the run's two files, authored by the
user, the unrelated file still staged and not in the commit, README still modified; the run page
showed "committed as c06358e7 on your branch".

**15.2 One run of the existing test suite** (the user approved the phase that listed it).

**15.3 A trial on a project of the user's** — waits for the repository and its verify command.
