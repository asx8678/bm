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
| 16 | Planner quality and notifications | 16.1–16.2 | clean planner rules (no build-only tasks, fewer tasks, less reading), planner spend, notifications |
| 17 | First real use | 17.1– | goals on the user's real repositories, fixes from what they show |
| 18 | Catch edge-case bugs | 18.1–18.3 | reviewer probes boundary inputs, planner names boundary cases, the user's goal wins in review |

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

**Status 15.2 (2026-09-30).** `mix test`: 199 passed, 6 excluded; `mix test --only live`: 5 passed
(qualification with the current planner/reader/writer profiles, milestone B gate). Nothing broke
in phases 12–15; no fixes were needed. Still: the planner, scheduler, reviewer, ask_planner,
freshness, protection and commit paths have no tests of their own (user's instruction); they were
checked by scratch scripts and live runs only.

**Status: Phase 15 done except 15.3** (a trial on a project of the user's, waiting for the
repository and its verify command).

**Status 15.3 (2026-09-30); Phase 15 done.** A trial on a second repository was run and later
removed at the user's request (the repository was not one the user had chosen). It led to fix F4:
a task that changed nothing but has a check now runs that check (and fails if it fails) instead
of being accepted unchecked; checked with the fake pi (`true` → accepted, `exit 3` → failed).

---

## Phase 16: planner quality and notifications

Scoped 2026-09-30 from trial findings (a build-only task; the planner's share of cost).
No tests (user's instruction); checked with a live goal on a trial clone (since removed).

**16.1 Planner quality.** The planner's rule list was rewritten: an earlier edit had spliced the
"BM comes back only if a task fails…" sentences onto the end of the blocked-goal rule and cut the
start of the "once the plan is closed" rule, so the planner had been reading a garbled rule. New
rules: read only what the plan needs; as few tasks as the goal needs (often one); every task
changes files — put build/test commands in the `check` of the task that changes the code. The
planner's own spend is kept in `run.planner["spend"]`; the run page shows "planner $x · work and
review $y" under the total. Checked live: one task, the build folded into its check, review approved; $0.058 = planner
$0.0285, review $0.0099, worker ≈$0.02.

**16.2 Notifications.** Run page: a colocated `.Notify` hook with a "Notify me" button (asks the
browser's permission); when the run ends, pauses, or an attempt waits for the user's decision
while the page is not focused, the tab title gets "● " (removed on focus) and, with permission, a
browser notification is shown. API: `waiting_for_you` on a run. `mix bm.goal`: terminal bell and a
line when the run ends, pauses, or waits for a decision. Checked: during a live run the open page's title gained "● " at the end and the button was
there (permission undecided in the headless browser, so no notification was shown); the
terminal printed the bell before the "done" line.

**Status: Phase 16 done (2026-09-30).**

---

## Phase 17: first real use

Started 2026-09-30 (branch `phase-17`). The first goal ran on a repository the user had **not**
chosen; at the user's request everything BM did there was undone (the file restored, BM's
checkpoint ref and private index removed) and BM's records of it deleted. Rule since then: BM
works only on a repository the user names.

**17.1 Finding F5 (fixed):** a worker whose build check failed because `node_modules` was out of
step with the lockfile ran `pnpm install --frozen-lockfile` to get it going. BM allowed it and
recorded nothing: git ignores `node_modules`, outside BM's snapshots. Now the policy refuses
dependency-changing commands in every mode (npm/pnpm/yarn/bun install·add·remove·update,
pip/uv/poetry/pipenv, bundle/gem, cargo add·install, mix deps.*, go get/install, brew, apt), with
a reason telling the model to report the task blocked and name the command; builds and tests stay
allowed. The worker prompt says to report environment problems instead of repairing them.
Checked by calling the policy on sample commands.

---

## Phase 18: catch edge-case bugs

Scoped 2026-09-30 from the sandbox trial: run 78's `truncate` passed its tests, the verify command
and the reviewer, yet `truncate("abcdef", 0)` returned 6 characters. No tests (user's instruction).

**18.1 Reviewer probes edge cases.** The reviewer works out the contract the task states or
implies and tries the changed code on boundary inputs (empty, zero, negative, the exact limit and
one past it, very large, unusual characters) with print-only one-off commands (`node -e`,
`python3 -c`, `mix run -e`), rejecting with the exact input and result. Because it now runs
commands, the coordinator snapshots after the review: if the reviewer changed any file, the
attempt is held (flag `reviewer_wrote`, verdict "invalid") for the user. Checked with the fake pi:
a reviewer writing `probe.txt` → attempt held, reason names the file.

**18.2 Planner names boundary cases.** For code with a contract, done_when names the boundary
cases and asks for tests covering them.

**18.3 The user's goal wins in review.** Proof run 1 (run 81, the run-78 goal re-run on a throwaway
sandbox clone reset to before run 78): the planner now named max 0 and the tests covered it, but
the planner's done_when said "max 0 or negative returns '…'" (1 character, still over max 0) and
the reviewer accepted it because the task allowed it. Fixed: the reviewer also gets the run's
original goal and is told the user's goal wins where the task restates the contract differently.
Proof run 2 (run 82, fresh clone, same goal): `truncate("abcdef", 0)` → `""`, results never over
max for max 0/1/2, tests include `truncate("", 0)`, the review reports probing max 0/1/2/3; 21 tests
pass; $0.13. One sample per run: the model can vary, so this lowers the risk rather than removing
it. The real sandbox was not touched (clones in /tmp).

**18.4 Review (2026-09-30), two bugs fixed.**
- *The policy refused the reviewer's probes.* Read-only mode (reviewer, planner, readers) read
  `>` and `=>` inside quoted code as redirections and code like `truncate(` as the `truncate`
  command, so `node -e "[0,1].forEach(m => …)"` and even `node -e "console.log(truncate('abcdef',
  0))"` were refused. Now quoted text is an argument: it is masked when finding redirections and
  command separators (double quotes holding `$(` or a backtick stay visible), and `sh -c` /
  `bash -lc` / `eval` strings are checked as commands of their own, which closes gaps workers
  had (`sh -c "cd x && git push"`, `bash -c 'npm install …'` and `eval "git push"` were allowed).
  Checked by comparing old and new decisions on 34 commands in both modes: only the reviewer's
  probes and harmless quoted `>` (`grep "a > b"`) became allowed; every command that was refused
  still is. Still refused: a heredoc body is read as shell (`cat <<'EOF' … x => x … EOF`).
- *Files the reviewer changed were left out of the held attempt.* The attempt kept the tree the
  reviewer was shown, so Revert left the reviewer's new files behind and was refused if it had
  edited one of the attempt's own files, and Keep checkpointed a tree that no longer matched the
  disk. Now whatever changed during the review becomes part of the attempt (like the verify
  command's changes): `tree_after` and `actual_writes` are taken after the review, flag
  `reviewer_wrote` (plus `user_owned_writes` if one of the user's files changed); a failed
  snapshot after the review holds the attempt instead of accepting it. The message says "files
  changed during the review", since the user's own edits in that window land there too. Checked
  with the fake pi: a probe with `=>` and `>` through the reviewer's policy → ran, approved; reviewer writes
  `probe.txt` and edits `out.txt` → held with both, Revert → clean `git status`; reviewer
  writes `probe.txt` → held, Keep → checkpoint tree equals the workspace.
- Known, not fixed: `python3 -c "import …"` writes `__pycache__/` in repositories that don't
  ignore it, which holds the attempt as a reviewer write.

**Status: Phase 18 done and reviewed (2026-09-30).**

---

## Phase 19: real use on the sandbox

Scoped 2026-09-30 by the user's choice (the open optional features have no evidence from real use
yet): confirm on `~/projects/bm-sandbox` itself, not a throwaway clone, that Phase 18's reviewer
catches boundary bugs, and fix what turns up. No tests (user's instruction).

**19.1 See what the reviewer ran.** The review records the reviewer's bash commands and the
policy's answer (allowed, or refused with the reason) with the review; the run page lists them
under the review's reason. Until now only the reviewer's own summary said whether it probed.

**Status 19.1 (2026-09-30).** `Bm.Review` returns the reviewer's bash commands (at most 40, 2,000
characters each) with the policy's answer; the coordinator stores them as `review.commands`, also
when files changed during the review; the run page lists them under the reason (✓ ran, ✕ refused
with the reason). Checked with the fake pi (run 87): a heredoc probe and a `python3 -c` import
listed as run, a `touch` after the verdict listed as refused with the policy's reason. Refused
`edit`/`write` calls are listed too (`write probe.txt`, checked the same way, run 91).

**19.2 Close 18.4's known limits.** A heredoc body (`node <<'EOF' … EOF`) is the command's input,
not shell, unless a shell reads it (`bash <<EOF` is checked as a command). Read-only sessions
(planner, reader, reviewer) run with `PYTHONDONTWRITEBYTECODE=1`, so a `python3 -c` probe
doesn't write `__pycache__/`.

**Status 19.2 (2026-09-30).** `Bm.Policy`: a heredoc body is blanked before the checks unless the
line holding `<<` runs a shell (then the body is checked as a command); one heredoc per line.
Compared with the policy before on 46 commands in both modes: only six read-only heredoc probes
changed (refused → allowed); `bash <<EOF` with `git push`, `sh <<X` with `rm -rf` outside, `cat
<<EOF | sh` with `npm install`, `git commit -F - <<EOF` and a command after a heredoc are still
refused. `Bm.Pi.Profile` gives roles without `edit` (planner, reader) `PYTHONDONTWRITEBYTECODE=1`.
Checked with the fake pi: the reviewer's `python3 -c "import mod"` left no `__pycache__/` (the
same import without it writes one) and the change was approved.

**19.3 Goals on the sandbox.** Two or three goals with contracts that have edge cases, started
with `mix bm.goal`, each change checked by hand (code read, own probes of the boundaries) and
committed with `mix bm.commit`. Findings go to TRIALS.md and are fixed in this phase.

**Status 19.3 (2026-09-30).** Runs 88–90 (TRIALS.md): `wrap`, `slugify` maxLength, the CLI `wrap`
command; each done in one task with the review approved, checked by hand, committed; $0.16. The
planner named the boundary cases every time and each reviewer probed them; no command refused,
no reviewer write. Fixed F6: recorded commands were cut at 500 characters (now 2,000). Not
exercised: a reviewer *catching* a boundary bug, since every worker got the edges right.

**Status: Phase 19 done (2026-09-30).** Open: a seeded-bug check (a worker made to write a change
that breaks its contract at one boundary, with tests that miss it, judged by the real reviewer)
would show whether the reviewer catches it; it needs the user's approval (a clone, ≈$0.05).

---

## Phase 20: real use beyond the sandbox

Scoped 2026-09-30 after Phase 19: the sandbox's goals now pass cleanly, and the optional
features still have no evidence from real use. No tests (user's instruction).

**20.1 Does the reviewer catch a boundary bug?** Phase 19's reviewers probed well but never had a
bug to catch. On throwaway clones of the sandbox (in /tmp; the real sandbox is not touched), a
goal with a clear contract runs with the real planner and reviewer, but the worker is told to
write a given implementation with one boundary bug and tests that miss it. Two samples: an
off-by-one at the exact limit (`<` for `<=`) and `max = 0` not handled. It passes if the reviewer
rejects and names the failing input. The run is ended after the first review (≈$0.05 each).

**Status 20.1 (2026-09-30): both caught.** Runs 92 and 93 (clones `/tmp/bm-sandbox-20a`, `-20b`),
real planner and reviewer, worker told to write the seeded files (it wrote them exactly; the tests
and `node --test` passed). Run 92 (`text.length < max`): rejected, "`ellipsize("hello", 5)` returns
"hell…" where the contract requires "hello" (verified with node -e)". Run 93 (no `max === 0`
case): rejected, "`ellipsize('hello', 0)` returns 'hell…' (5 chars) instead of ''". Both times the
recorded command was a `node -e` probe of exactly that input, BM reverted the change and gave the
reason to the planner; the runs were then ended. $0.038 and $0.043. In both runs the planner had
named the case in done_when (exact limit, max 0), so the reviewer had the case in front of it;
two samples of the classic boundaries, not proof for every bug.

**20.2 A trial on a project of the user's.** Waits for the user to name the repository and its
verify command.

**20.3 Fix what 20.1 and 20.2 find.**

**Status: Phase 20 done with 20.1 (2026-09-30).** 20.1 found nothing to fix. 20.2 did not start: it
needs a repository the user names, so it moves out of this phase and waits as its own item
(below); 20.3 is empty.

**Waiting for the user: a trial on one of their projects.** Starts when the user names the
repository and its verify command (and says whether BM may commit accepted changes there with
`mix bm.commit`). BM never picks a repository itself.

---

## Phase 21: resume after a restart

Chosen by the user 2026-09-30. Evidence: trial runs 62 and 68 were interrupted by BM restarts and
needed a manual Resume planning; after every restart a goal run pauses ("planner lost") even when
nothing waits for the user. No tests (user's instruction).

**21.1 An interruption is not a failure.** In a goal run, an attempt that recovery finds
interrupted with no changes (`failed`, "interrupted (no changes; safe to run again)") no longer
fails its task: the task goes back to `queued`, so the scheduler runs it again. Until now it
counted as the task's one re-plan, and if the interrupted attempt was already the re-planned one,
the resumed run ended "failed again after its re-plan". Single-task runs keep the task failed
(nothing would run it again; the user re-runs it).

**21.2 Resume by itself after a restart.** At application start only (not when a coordinator
alone restarts), a goal run whose planner was lost resumes planning in a new session instead of
waiting, when all hold: automatic resume is on (`config :bm, auto_resume:`, default true), the
lane is free (no interrupted or held changes wait for the user), the budget is not spent, and the
run was resumed this way fewer than 3 times (a crash loop stops there). Otherwise it pauses as
before, and the reason says why it did not resume. Attempts that changed files are never retried
or reverted by themselves: the recovery snapshot cannot tell the worker's writes from the user's.

**21.3 `mix bm.goal` waits out a restart.** It gave up ("Lost the run") on the first poll that
found the server down. Now `Bm.CLI.fetch/1` tells a server that does not answer from an error it
answered with; `mix bm.goal` waits up to 2 minutes, saying so, and follows the run again.
`mix bm.runs`, `bm.status` and `bm.commit` are unchanged.

**Status 21.1–21.2 (2026-09-30).** `Recovery.recover/1` queues the task again when a goal run's
attempt is interrupted with no changes (and no longer touches the task of an attempt that was not
orphaned); `Recovery.run/0` passes `auto_resume: true` to `recover_planner/2`, which reloads the
run (an attempt with changes may have paused it), pauses it as before and then resumes it through
`Coordinator.resume_planning/2` or records why not. Checked with the fake pi across two BEAMs (A
starts a run and halts while the worker runs; B runs the startup recovery): no changes → resumed
("1 of 3" note, attempt failed "interrupted", task queued, new planner); worker had written →
paused, "changes wait for your decision (Keep or Revert)"; budget spent → paused, "the
run's budget is spent"; `auto_resumes` 3 → paused, "already resumed by itself 3 times";
`auto_resume: false` → paused, "turned off". Live on a sandbox clone (`/tmp/bm-sandbox-21`): run
104, the dev server stopped (SIGTERM) as soon as the worker ran and started again; recovery
queued the task, resumed planning, the task ran again and was accepted, review approved, run done
($0.073, of which ≈$0.014 for the resumed planner's extra turn).

**Status 21.3 (2026-09-30).** Live, run 105: the server was down 7 s while `mix bm.goal` followed
the run; it printed "BM does not answer (restarting?)…", then "BM answers again." and the rest of
the run through "done" ($0.040). Both runs' changes checked by hand (tests 50 and 56, own probes).

Review fixes: recovery runs next to the web server's start, so `mix bm.goal` could see a run in
its short "planner lost" pause before it resumes, and stop there. It now looks again (up to 5
polls) at a pause whose reason is recovery's bare "planner lost: BM stopped…" without "; not
resumed by itself" or "; resuming failed" (checked by reading and on those reason strings). The
reason for a lane held before the restart no longer says "interrupted". Also changed: when an
attempt turns out not to be orphaned (`:stale`), recovery leaves its task and run alone (it used
to mark the task failed and could pause the run).

Not seen live: a restart during the planner's first turn (no attempt yet; same path, lane free →
resume) and during verification or review (the attempt has changes → paused for the user). Single-task
runs are unchanged: an interrupted task fails and the user runs it again.

**Status: Phase 21 done (2026-09-30).** Not done: a resumed run whose plan was already closed still
spends one planner turn before its queued task runs (≈$0.014 in each of runs 104 and 105).

---

## Phase 22: a cheaper resume

Chosen by the user 2026-09-30 after Phase 21. No tests (user's instruction).

**22.1 No planner turn to resume a closed plan.** A run that resumes (by itself or by the user)
with its plan already closed starts its new planner session without a turn: the scheduler runs
the queued task straight away (runs 104 and 105 each spent ≈$0.014 on a turn that only restated
the closed plan). If a later result or a worker's question needs the planner, that first turn
carries the goal, the repository context and the tasks so far ahead of its own text, so the new
session knows the run. A plan that was still open resumes with its turn as before.

**22.2 Scratch runs finished.** Runs 80, 83 and 100–103 (BM's own checks in temporary
repositories, left paused) were finished as cancelled, with a reason saying so.

**Status 22.1 (2026-09-30).** `Bm.Prompts.planner_resume/3` (still used for an open plan) splits
into `planner_resumed/3` (goal, repository, tasks so far) plus the instruction to continue; a planner started with `resume: true`
on a closed plan logs a note, goes idle and schedules at once, and its first later turn sends
`planner_resumed/3` ahead of its own text (the log keeps the turn's text and a note, since
entries are cut at 2,000 characters). Checked with the fake pi across two BEAMs (run 107): no turn
after the resume, the queued task ran again, its failure reached the planner with the context
first (the fake planner's echo starts with "You are the BM planner"), the reminder after it
without. Live (run 108, sandbox clone, dev server restarted while the worker ran): no planner turn
after the resume, the task was accepted, review approved, run done by D22; planner spend $0.013
(runs 104 and 105, before: $0.028 with the extra turn); total $0.052.
Also affected: the run page's Resume planning on a closed plan now takes no turn either. Not
seen with the real model: a later turn carrying the context (run 108 needed none; only the fake
pi, which echoes, went through it).

**Status 22.2 (2026-09-30).** Done (`Runs.finish_run/3`, reason "scratch run from BM's own checks
(temporary repository); finished"); no unfinished runs are left.

**Status: Phase 22 done (2026-09-30).**

---

## Phases 23–25: the finish line

Scoped together 2026-09-30 at the user's request ("plan phases 23 and 25, make them together",
read as 23 to 25, the three phases the user was shown as the finish line). None of these has
evidence from a trial yet (FEATURES.md asks for evidence before optional features); the user
chose to build them anyway to finish the list. The trial on a project of the user's stays
waiting for a repository. No tests (user's instruction): each step is checked with the fake pi
and, where it matters, live. Each phase is reviewed, then merged into `main`; pushed at the end.

## Phase 23: safety during a run

**23.1 Undo a task while its run is unfinished.** Until now only finished runs could undo a task
(13.3). Now also: a *paused* goal run (its planner is not scheduling, so an undo cannot land
inside a planner turn, which would read as "the planner changed files"), and an active
single-task run with no attempt running. Same dependency check and conditional restore as 13.3.
Two things are new: BM records the workspace after the undo as its own last state (13.1 compares
the workspace with the latest attempt's tree and would otherwise protect the restored files as
the user's), and in a goal run the planner hears of it: the task's delivery is dropped so the
next scheduling reports it again, as "undone by the user; its changes are reverted; propose it
again only if the goal still needs it". A run whose plan then ends without that task ends
"failed: not every task succeeded", with the task named as undone by the user.

**23.2 A silent model stops a planner or review turn.** Workers already stop after 3 minutes
without a pi event (plus tool and total limits). The planner waited up to 15 minutes per turn
and the reviewer 5 minutes, however quiet the model was. Now the same 3-minute silence rule
applies to both: the planner turn is stopped and the run paused with the reason; the review
counts as not run (the existing "not reviewed" path). Cost estimates for requests in flight are
left out: the stream's partial usage could not be shown to carry a cost.

**Status 23.1 (2026-09-30).** `Coordinator.revert_task/2` also works in an unfinished run
(`revert_task_in_run`): refused while an attempt runs, while the lane is held, and for an active
goal run (`:run_not_paused`). New `Coordinator.pause_by_user/2` and a Pause button for an active
goal run: the planner is stopped (and no longer watched), the run paused "paused by the user"; a
running attempt finishes first. After an undo, `remember_workspace/2` stores the workspace tree in
`run.baseline["known_tree"]` with the newest attempt that ran, and `last_known_tree/1` uses it
while no attempt ran since (first version used the newest attempt of all, which at admission is
the one being admitted: task 3's write was refused as the user's; fixed). `Runs.drop_delivery/1`
makes the planner hear of the undo; the undone attempt gets flag `undone` and "undone by the
user; its changes are reverted"; the planner's delivery adds "Propose it again only if the goal
still needs it"; a run that ends without the task names it "undone by the user". Checked with the
fake pi: single-task run t1, t2, undo t1 (a.txt gone), t3 writes a.txt → accepted, nothing
protected; goal run: undo refused while t2 ran, Pause while t2 ran → planner stopped, t2 accepted
after, run "paused by the user"; undo t1 → a.txt gone, b.txt kept; Resume → the planner's results
say "t1: cancelled … undone by the user … Propose it again only if the goal still needs it".

**Status 23.2 (2026-09-30).** Planner: `stall_timeout` (3 minutes) checked on its tick, from the
time of its model's last pi event, not while one of its commands runs; a silent planning turn
pauses the run ("the planner's model sent nothing for 3 minutes"), a silent answer turn leaves the
worker's question unanswered. Reviewer: no pi event for 3 minutes while no command runs ends the
review as `:model_silent` (not reviewed); `config :bm, review_silence_ms:` sets it. Checked with
the fake pi at 2 s: a hanging planner turn → run paused after 2.3 s with the reason; a hanging
reviewer → the change accepted with `not_reviewed`, reason `:model_silent`.

**Status: Phase 23 done (2026-09-30).**

## Phase 24: control from anywhere

**24.1 Approval inbox.** pi dialogs that are not BM's own (`select`, `confirm`, `input`,
`editor`, from other extensions) were declined at once. In a worker's attempt they now wait for
the user: the run page shows the question with its choices and answer controls, and the answer
goes back to pi. An approval not answered within 2 minutes is declined (cancelled), and noted.
While one waits, the attempt's silence clock is held, like during a tool call. The planner and
the reviewer still decline such dialogs (they are BM's own sessions).

**24.2 `mix bm.attach`.** Follows an existing run from the terminal (the same output as
`mix bm.goal`, whose follow code moves into `Bm.CLI`), and when the run waits for a decision or
an approval, asks for it once in the terminal. New API endpoints: keep, revert, cancel, and
answering an approval.

**Status 24.1 (2026-09-30).** `Bm.Pi.Agent` started with `approvals: true` (the coordinator's
workers) forwards `select`/`confirm`/`input`/`editor` requests of other extensions to its owner
(op `approval`) and answers them in pi's shapes (`confirmed`, `value`, `cancelled`); the
transcript notes the question and the answer. The coordinator keeps them in `approvals` (also in
`@late_fields`), declines each after `approval_timeout` (2 minutes, or pi's own `timeout` if
sooner), holds the stall check while one waits, drops them when the attempt ends, and answers
through `Coordinator.answer_approval/3`. The run page shows a card per question (Yes/No, one
button per option, a text field or text area, Decline); `GET /api/runs/:id` lists them and counts
them as waiting for the user; `POST /api/runs/:id/approvals/:dialog_id` answers. The fake pi got
a `{"dialog": …}` work step. Checked on a scratch BEAM serving the site on port 4011, the worker's
stall limit set to 1 s: a confirm answered with the page's Yes in headless Chrome
(`confirmed: true`), a select through the API (`value: "B"`), an input through the page's form
(`value: "Ada"`), an editor left alone (declined at its 1.5 s timeout, `cancelled: true`); the
attempt was accepted, never stopped for silence; the transcript holds each question and answer.
A first pass declined the confirm after its 90 s timeout while I was slow to click: correct.

**Status 24.2 (2026-09-30).** `Bm.CLI.follow/2` (moved from `mix bm.goal`, which now uses it)
prints tasks, approvals and decisions; with `ask: true` it asks once per approval (y/n/d, an
option number, or text) and once per held attempt (k/r), an empty answer or end of input leaving
it for the page. `mix bm.attach BM-n` (`--watch` only follows). API: `POST /api/runs/:id/keep`,
`/revert`, `/cancel` for the workspace's current run, 404 for other actions. Checked on the 4011
scratch server with answers piped in (`y`, `2`, `r`): pi got `confirmed: true` and `value: "B"`,
the held attempt (verify `false`) was reverted (out.txt gone), and attach followed the run to done.

**Status: Phase 24 done (2026-09-30).**

## Phase 25: a supervisor for attempts

Rules only, checked with the existing periodic limits check; no model calls (a model-based drift
check is left out: no evidence, and it would cost per check).

**25.1 Steer the worker.** `Bm.Pi.steer/2` (pi's `steer`: delivered after the current tool calls,
before the next model call). The supervisor steers once, and says so in the attempt's activity:
when the worker writes a file outside the task's declared `writes` (allowed as before, flagged at
the end as before, but now the worker is told at once); and when an attempt has run for a while
with many tool calls but no change in the workspace. If the no-progress case repeats after the
steer, the attempt is cancelled with the reason.

**25.2 Run-level progress.** A goal run in which three attempts in a row ended without an accepted
task is paused for the user ("no progress: …").

**Status 25.1 (2026-09-30).** `Bm.Pi.steer/2` (pi's `steer` command; the transcript notes "BM told
the worker: …"); the fake pi answers it and can log it (`FAKE_STEER_LOG`). Coordinator: an allowed
edit/write outside `task.writes` steers once per file (`steer_drift`); `check_progress` in the
limits check steers a writer attempt once after `progress_after` (6 minutes) with at least
`progress_calls` (30) tool calls and no changed file (a snapshot compared with `tree_before`), and
cancels it ("no progress: …") if still nothing changed after as long again; read-only attempts
are left alone. New state fields in `@late_fields`, whose guard now checks the newest field.
Checked with the fake pi: a task declaring a.txt that writes b.txt twice → one steer, the notice in
the transcript, accepted with `undeclared_writes`; 4 tool calls then busy (limits 2 s / 3 calls) →
steered at ≈2 s, cancelled at 4.5 s "no progress: 4 tool calls and no changed file" (a first try
with four identical `true` commands met the repeat guard instead).

**Status 25.2 (2026-09-30).** The planner's scheduler pauses the run before admitting a task when
the last 3 finished attempts ended without an accepted task (not counted: interruptions by a
restart, undos, stops by the user; nothing before `planner["progress_mark"]`, set at such a pause
so a resume starts a new count). Checked with the fake pi: four tasks whose checks fail → paused
"no progress: the last 3 attempts ended without an accepted task" with t4 still queued.

Notes: of the 36 attempts BM made in real repositories so far (trial clone, sandbox), none wrote
outside its declared files, so the drift steer would not have fired in them; its text leaves the
worker free to go on when the task needs the file. Once past its thresholds, the no-progress
check takes a snapshot on each limits check (every 45 s by default) until a file changes or the
attempt is cancelled, at most about 8 per attempt. Attempts BM cancelled (silence, time,
no progress) count toward the run-level streak on purpose.

Not seen with the real model in Phases 23–25: every check used the fake pi (the approval inbox also
through the real page in headless Chrome and the real API). Worth watching in real use: whether a
real worker heeds a steer, and a real extension's dialog (no BM profile loads one that asks yet).

**Status: Phase 25 done (2026-09-30). Phases 23–25 done.**

---

## Phase 26: live checks of Phases 23–25

Started 2026-09-30 on the user's "start working on next" without a named repository (the trial on
a project of the user's still waits for one). Phases 23–25 were checked with the fake pi only (see
the Phase 25 notes); this phase runs them with the real model on throwaway clones of the sandbox
in /tmp (the sandbox itself is not touched). No tests (user's instruction).

**26.1 Nothing misfires on a normal run.** A goal with two or three tasks, default settings, through
the dev server and `mix bm.goal`. Passes if the outcome is as before Phases 23–25: no steer, no
supervisor pause, no planner or review turn stopped for silence.

**26.2 Undo during a run with the real planner.** Pause after the first task is accepted, undo it,
Resume. Recorded: what the real planner does with "undone by the user; propose it again only if
the goal still needs it".

**26.3 A real worker gets a steer.** A scratch BEAM with the real pi and low no-progress thresholds
(≈20 s, 3 tool calls) on a task that needs some reading first. Passes if, after the steer, the
worker changes a file or submits blocked; if it changes a file before the threshold, the steer was
not provoked and the thresholds are noted as sane.

Left out: the approval inbox (no BM profile loads an extension that asks the user anything).
Anything to fix goes into 26.4.

**26.4 Pause while an attempt runs.** Found while planning 26.2: the Pause button (23.1) showed only
when no attempt ran, which in a goal run is rarely: the next task starts as soon as one ends. The
coordinator already allowed it (the planner stops, the attempt finishes). The run page now offers
Pause next to Stop while a goal run's attempt runs.

**Status 26.1 (2026-09-30).** Run 132 on `/tmp/bm-sandbox-26a` (`mix bm.goal`, dev server, default
settings): `pad(text, width, align)` then a `pad` CLI command, 2 tasks, both reviews approved, no
steer, no supervisor pause, no silence stop, ended without a closing planner turn; $0.150. Checked
by hand: 59 tests pass, left/right/center padding right, the CLI's bad widths refused. Noted: the
worker defaults `align` to left only when it is left out; an explicit `undefined` throws (allowed
by "otherwise throw a RangeError", unusual for JavaScript).

**Status 26.2 (2026-09-30).** Run 133 on `/tmp/bm-sandbox-26b`, real planner and worker, the site
served on port 4011 from a scratch BEAM and clicked in headless Chrome: Pause while task 1's worker
ran (26.4) → paused, task 2 not started; task 1 accepted after; Undo this task (confirmation
accepted) → undone; Resume planning → no planner turn, then the task's results with the run's
context first. The real planner re-proposed the task: "it was previously cancelled and reverted,
so the goal still needs it" (the goal does ask for it); revision 2 and then the CLI task were
accepted, run done; $0.143; 55 tests pass.

**Status 26.3 (2026-09-30).** Single-task runs on fresh clones, a refactor that needs reading first
(shared integer validation for `truncate.js`, `wrap.js` and the CLI). Run 134 (thresholds 15 s / 3
calls): the worker read three files, wrote at ≈10 s, accepted in 17 s; no steer (not provoked:
real work is far below the 6-minute default). Run 135 (4 s / 2 calls): after 4 tool calls the
transcript shows "BM told the worker: After 4 seconds and 4 tool calls this attempt has changed no
file…"; the worker's next actions were the write and the three edits; accepted in 11 s, not
cancelled. $0.032 and $0.023.

**Status: Phase 26 done (2026-09-30).** Total live cost $0.35. The approval inbox is still seen with
the fake pi only (no real extension asks).

---

## Phase 27: housekeeping

Scoped 2026-09-30 from a check of what else needs doing (after Phase 26, nothing is unfinished).

**27.1 README.** The README was Phoenix's default; it now says what BM is, how to set it up and
start it, the terminal commands, the safety model, and where the docs are.

**27.2 Stale docs.** ARCHITECTURE.md §12 listed only phases up to 8; BENCHMARK_GOALS.md holds the
Phase 8 numbers (the 9.4 re-run was stopped) without saying so.

**27.3 Leftovers.** Merged local branches deleted; throwaway sandbox clones in /tmp removed.

Waiting for the user: running the existing test suite (not run since Phase 15.2; the user's
instruction is no tests unless approved), and deleting BM's own scratch runs from the dev
database (125 of 131 runs point at temporary directories).

**Status 27.1–27.3 (2026-09-30).** README.md rewritten (commands checked against `mix help`);
ARCHITECTURE.md §12 has a summary of phases 9–26 and says how they were checked; BENCHMARK_GOALS.md
says its numbers are from Phase 8 and how to refresh them; ten merged local branches deleted
(`git branch -d`); the throwaway sandbox clones in /tmp removed (18, 18b, 20a, 20b, 21; their runs'
pages still load). The two items that wait for the user are unchanged.

**Status 27.4 (2026-09-30): the test suite, approved by the user for this run.** First run: 192 of
199 passed. Five failures came from a row my own Phase 24 scratch check had committed to the *test*
database (it ran under `MIX_ENV=test` with the sandbox in auto mode and crashed before cleaning up):
an attempt left `running` that every recovery test saw. The test database was dropped and
recreated. One test expected the planner's environment to be empty (it has
`PYTHONDONTWRITEBYTECODE` since 19.2): updated. One failure was a real bug: since 17.1 the
dependency check answered first for `npm`, `mix`, `cargo` and `gem` and let their publishing
commands through (`npm publish`, `mix hex.publish`, `cargo publish`, `gem push`); fixed so they
still reach the publishing check. Second run: 199 passed, 6 excluded; `mix precommit` passes.

**Status 27.5 (2026-09-30): scratch data, approved by the user.** Deleted from the dev database, in
one transaction: 125 finished runs whose repositories were in temporary directories (BM's own
checks; tasks, attempts and deliveries went with them), 113 workspaces left without runs, and 709
bridge requests of those attempts and planners. Kept: the sandbox's 6 runs (77–79, 88–90).

**Status: Phase 27 done (2026-09-30).**

---

## Phase 28: BM on its own code

Chosen by the user 2026-09-30 ("yes BM"): the trial on a real project runs on BM itself, on a
fresh clone in /tmp (never the checkout the dev server runs from). Verify command
`mix compile --warnings-as-errors && mix format --check-formatted`; the goals ask for no new or run
tests (the user's instruction). Each accepted change is checked by hand, including running it from
the clone, and committed in the clone with `mix bm.commit` so the next goal builds on it; nothing
reaches the real repository unless the user asks for it.

The user picked three goals from real gaps between the terminal and BM:

**28.1 Status filter.** `GET /api/runs?status=…` and `mix bm.runs --status …` (the query supported a
status already; the API never passed one).

**28.2 `mix bm.status` shows what a run waits for.** Pending approvals and a held attempt, with a
hint to use `mix bm.attach` (the API has reported them since Phase 24).

**28.3 Pause, Resume and Undo from the terminal.** API endpoints and `mix bm.pause`, `mix bm.resume`,
`mix bm.undo`, with the run page's rules.

**28.4 A stopped attempt's wait is reported (found in 28.1).** When BM stops an attempt itself (a
limit, repeated calls) after it changed files, the lane is held for the user's Keep or Revert; the
run page showed it, but the API's `waiting_for_you` looked only for held or reconciling attempts,
so `mix bm.goal` said nothing and the run sat. The API now takes the wait from the coordinator's
lane and adds `decision` (task, attempt status, reason); `Bm.CLI.follow/2` asks for that decision.
Committed in the real repository (and brought into the clone before 28.2).

**Status 28.1 (2026-09-30).** Run 136, $0.314. The first attempt put `String.trim/1` in a guard (does
not compile) and then repeated the same failing edit until the repeat guard cancelled it; the run
then waited silently (28.4). Reverted through `POST /api/runs/136/revert`; the planner re-planned
and the second attempt was accepted, review approved. Checked by hand on the clone's own server
(port 4012): `?status=done` lists only done runs, `paused` none, `bogus` gives 422 "Unknown status.
Allowed: active, paused, done, failed, cancelled."; `mix bm.runs --status …` shows the same.

**Status 28.2 (2026-09-30).** Run 137, $0.174, one task, review approved. Checked with a staged
run on a scratch server (real repository's code, fake pi): while the worker's select question
waited, the clone's `mix bm.status` printed "Which mode? A, B" and the hint; after the attempt
was stopped with a file written, it printed "ask waits for Keep or Revert", and the API reported
`waiting_for_you: true` with the decision (28.4), which `mix bm.attach --watch` announced.

**Status 28.3 (2026-09-30).** Run 139, $0.563, two tasks. The reviewer rejected the first API
attempt with a real bug: pause and resume succeed with `{:ok, run}` but the shared helper expected
`:ok`, so a successful pause would have answered 404; BM reverted it, the re-planned task and then
the three mix tasks were accepted. Checked on the clone's server with a staged goal run: `mix
bm.pause` while task 1 ran → paused; again → "only an active goal run can be paused"; `mix bm.undo`
with an unknown key → "No such task in this run."; on t1 → a.txt gone; `mix bm.resume` → resumed,
t1 cancelled, t2 blocked. Missed by the reviewer: `mix bm.undo`'s moduledoc cites plan 15.1 / D26
(committing) instead of 13.3 / 23.1 / D28, and leaves out active single-task runs.

**Status: Phase 28 done (2026-09-30).** Three goals, all accepted, $1.05. The clone
`/tmp/bm-trial-28` holds them as commits on top of the real repository's phase-28 branch; they
reach the real repository only if the user asks.

**28.5 Brought into the real repository (2026-09-30, at the user's request).** The three commits
BM made in the clone (runs 136, 137, 139) were cherry-picked onto `main` (the clone's copy of the
28.4 fix was skipped: `main` has it). Fixed by hand: all three new mix tasks (`bm.pause`,
`bm.resume`, `bm.undo`) had copied `mix bm.commit`'s reference "plan 15.1, decision D26" into
their moduledocs; they now name their own plans (23.1/26.4, 7.9/22.1, 13.3/23.1 and D28) and say
when each works. Checked against the dev server: `mix bm.runs --status done` and `--status bogus`,
pause and resume refused for a finished run, `mix bm.undo` with an unknown key refused,
`mix bm.status` unchanged for a run that waits for nothing.

---

## Benchmark refresh (2026-09-30, after Phase 28)

The user ran `mix bm.bench --goals` on the current code (BENCHMARK_GOALS.md; the single-task
benchmark was not re-run). Same three goals, three runs per mode, zro/glm-5.3:

| | Plain pi | BM, Phase 8 | BM now |
|---|---|---|---|
| Verified | 9 / 9 | 9 / 9 | 6 / 9 |
| Cost | $0.132 | $0.597 | $0.330 |
| Wall time | 84 s | 356 s | 205 s |
| User's uncommitted file intact | 0 / 3 | 3 / 3 | 3 / 3 |

- BM costs 45 % less and takes 42 % less time than in Phase 8: ≈2.5× plain pi's cost and 2.4× its
  time, down from ≈5×. The planner now plans these small goals as one task and needs no closing
  turn (Phases 9 and 22).
- `shapes` and `calc_cli`: BM verified 6 / 6 ($0.03–0.06, 17–46 s each).
- `text_tools` needs `text.py`, which holds the user's uncommitted edit. BM's planner refused all
  three times ("the goal requires modifying text.py … but text.py contains the user's uncommitted
  changes") and left the file intact: the intended outcome (F1/F3 in Phase 11/14). In Phase 8 BM
  was counted verified there by putting the work into a new file the goal's check accepted.
  Plain pi finished it every time by changing the user's file.
- The report's header no longer says "plan step 8.3"; benchmark fixtures get time-based names and
  never reuse a leftover folder (`System.unique_integer` restarts in each new BEAM, and a stopped
  run leaves its folder behind; one from the stopped Phase 9 run was still there).

---

## Phase 29: is the UI wired?

Asked by the user 2026-10-01: much was built, little changed in the UI; check that everything
is wired. Checked every LiveView event against its handler and template (all wired; `phx-click="go"`
is only a doc example; `/flow` is an unlinked Svelte Flow demo page from the prototype), each
feature since Phase 9 for a place in the UI, and the pages in headless Chrome at desktop and phone
width. Found and fixed:

- **Run page header on a phone:** the title block could shrink to a sliver next to the cost (one
  word per line; a long goal filled a whole screen). It now takes the full row on small screens;
  long goals show three lines and expand on a click.
- **Tasks page pre-filled a removed checkout** (the last used workspace, a deleted clone). It now
  pre-fills the last used workspace that still exists.
- **The runs list never updated and could not show that a run waits for the user.** While it
  shows an unfinished run it reloads every 5 s, and a run whose lane is held (Keep or Revert) or
  whose worker asks a question gets a "Needs you" badge (from running coordinators only).
- **An attempt's Activity hid BM's notes** (a steer, an approval, a stop) inside a closed fold; the
  summary now counts them ("1 note from BM").

Checked: run 89 on a phone (header wraps, title clamped; page 3,263 → 1,680 px); the Tasks page
pre-fills the sandbox; run 136's Activity reads "16 tool calls, 5 failed · 1 note from BM"; a
staged held run on a scratch server (fake pi) showed "Needs you", and after a revert through the
API the badge went away within the refresh, without a reload.

Not done (decisions for the user): workspace settings that the code reads but no page sets
(review on or off, how many runs' checkpoints to keep); whether to remove the `/flow` demo page.

**Status: Phase 29 done (2026-10-01).**

---

## Phase 30: the flow merged into Chat

Asked by the user 2026-10-01: the /flow page was a canvas connected to nothing, and the Chat
page's canvas showed a single static agent node; merge the flow into Chat and wire it, and list
any other pages that are not linked.

- **/flow removed** (FlowLive, its route and its test). The only other unlinked pages are Phoenix's
  development tools, `/dev/dashboard` and `/dev/mailbox` (dev environment only).
- **Chat canvas is live:** the agent and its 12 most recent tool calls, one node each (running,
  done, failed), linked to the agent, updated as calls start and end; a click on a node opens a
  details panel (tool, status, its arguments as pi reports them, cut at 80 characters; for the
  agent: status, model, folder, tokens, and that BM does not guard it); a second click or ✕
  closes it.
- **Chat actions** (above the messages, so also on phones): "Run as a guarded goal" opens the Tasks
  page with the last request and the chat's folder filled in (`/?goal=…&path=…`, which the Tasks
  page now reads); "New conversation" (pi's new_session; asks first).
- **Run page canvas:** a click on the planner node scrolls to the planner panel, on a task node to
  its latest attempt (or its task card), outlined for a moment.
- Svelte Flow default nodes follow the theme (the white boxes of the old /flow page).

Checked in headless Chrome against the dev server: /flow → 404; a read-only chat request made two
tool calls, which appeared as two "Done" nodes linked to the agent; clicking the second opened
"Tool call #2 · fabric_exec · Done" with its arguments; the "Run as a guarded goal" link carried
the request and folder, and the Tasks page filled the goal in from `?goal=`; on run 139 a click on
a task node scrolled from the top to `attempts-197` and outlined it.

**Status: Phase 30 done (2026-10-01).**


---

## Phases 31–35: plans in the chat

Asked by the user 2026-10-01: drop the Tasks page; in the chat the model makes a plan through a
tool, the plan holds tasks with much more content, visible next to the chat; refine them by chat
or by clicking (Refine, Dig deeper); question the request (look at the code, check the scope,
ask) when the user asks for it. The user chose a plan board beside the chat and questioning
only on request. Running a plan comes after these phases.

## Phase 31: plans and tasks as drafts

**31.1 Tables.** `plans` (workspace, title, goal, findings in the code, status drafting / ready /
archived, the run it became, later) and `plan_tasks` (key, position, title, why, what exists,
approach, files, done when, depends on, risks, open questions, check, revision). Separate from
runs and tasks on purpose: a plan is a draft that changes while it is discussed; a run is an
execution with checkpoints, recovery and budgets. Running a plan later copies its tasks into a
goal run.

**31.2 `Bm.Plans`.** Create a plan; add, update (revision + 1), remove and reorder tasks; checks
(a key per plan, `snake_case`; dependencies name tasks of the plan and make no cycle; removing a
task others depend on is refused unless they drop it; files are relative paths inside the
checkout); list plans and tasks. Every change is broadcast (`plan:<id>`, and `plans` for the
list), for the board in Phase 33.

**Status: Phase 31 done (2026-10-01).** Migration `create_plans` (tables `plans`, `plan_tasks`),
schemas `Bm.Plans.Plan` and `Bm.Plans.Task`, context `Bm.Plans` (create/update a plan; add, insert
before, update, remove and reorder tasks; checks; broadcasts on `plan:<id>` and `plans`). Checked
with a scratch script on the dev database (plan deleted afterwards): three tasks in order;
refused: a key that is not snake_case, a duplicate key, an unknown dependency, a cycle, a task
depending on itself, files outside the checkout (`../secret`, `/etc/passwd`), removing a task
another depends on, a reorder that leaves a key out; an update bumped the revision to 2; insert
before and reorder worked; every change was broadcast; deleting the plan removed its tasks.


## Phase 32: planning tools in the chat

**32.1 The chat agent.** `Bm.Chat` (one process in the supervision tree) owns one pi agent in a
new `:chat` profile: read tools and `bash`, under `bm_guard` in read-only mode (`Bm.Policy`), plus
the `bm_chat` extension and standing instructions (`priv/pi/prompts/chat.md`, passed with
`--append-system-prompt`). It keeps the repository, the current plan and the agent's open
questions, broadcasts them on `chat`, and starts the agent lazily (and again after the repository
changes). The repository is chosen on first use, not at boot.

**32.2 Plan tools.** `create_plan`, `add_task`, `update_task`, `remove_task`, `get_plan` and
`ask_user` are `bm:` dialogs answered by `Bm.Chat` through `Bm.Plans`: every change is checked and
stored by the BEAM, the model hears the plan as it now stands, and a refusal comes back as a tool
error with the reason (also logged).

**32.3 The page.** `/chat` uses `Bm.Chat` instead of the unguarded shared pi session: a
repository picker (existing workspaces as suggestions), the current plan's line (title, task
count), question cards whose answers go back together as one message, the read-only note and
planning suggestions. The live canvas, details panel, New conversation and Run as a guarded goal
stay.

**Status: Phase 32 done (2026-10-01).** Checked live on `bm-sandbox` (served on another port,
headless Chrome): "Prepare a plan to add reverse(text) … with a test" made plan 2 with three
filled tasks (`implement_reverse` → `export_reverse` → `test_reverse`, files, done-when, a check);
one `add_task` was refused and the model corrected it. Asked to write `NOTE.txt`, the agent was
blocked ("This task is read-only") and the checkout stayed clean. `ask_user` showed two question
cards; picking an answer for each sent them as one message and the model went on. Fixed during the
check: the page subscribed to the agent twice once it became ready (every event showed twice); an agent replaced while still starting is now stopped instead of left running.
Known: the current plan is held in memory, so after a restart the chat starts without one (the
plans list comes in Phase 35). The chat LiveView test was cut to the render check (the old ones
drove the shared `main` agent); tests not run, per the user's instruction.

## Phase 33: the plan board

**33.1 Board.** The chat page's right pane switches between Plan (default) and Activity (the
live canvas, kept mounted underneath so it keeps its state). The board shows the current plan:
title, status, goal, what the agent found in the code (folded), then the tasks as numbered cards
(title, key, dependencies, revisions, open questions, why, files); a card opens to what exists,
approach, done when, risks, open questions and the check. A task added or changed flashes and
scrolls into view.

**33.2 Card actions.** Refine opens a box on the card for what should change and sends it to the
agent as "Refine task <key> …"; Dig deeper asks the agent to read the code for that task, make
it concrete with `update_task` and propose real choices with `ask_user`; both wait while the agent
works. Remove deletes the task directly (`Bm.Chat.remove_task/1`, refused with the reason while
other tasks depend on it); the agent hears of board changes at the start of the next message
("[On the plan board since your last turn: …]"), and its instructions say so.

**Status: Phase 33 done (2026-10-01).** Checked live on `bm-sandbox` (served on another port,
headless Chrome): the empty board, then a capitalize(text) plan filling in live (three cards);
answering the agent's two questions revised task 1 and 2; Remove on task 1 was refused
("test_capitalize, export_and_verify depend on it"), Remove on task 3 worked and the agent later
said "the export task you removed stays removed"; a card opened to its full content; Refine
("also test several spaces…") made the agent update the test task (and task 1's done-when to
match); Dig deeper on task 1 read the code and proposed two choices as question cards. The
checkout stayed clean. Known: the board shows from the md breakpoint up (phones see the chat
and the plan line); a removal while the agent is mid-answer reaches it only with the next message.

## Phase 34: questioning on request

**34.1 Grilling.** Only when the user asks ("grill this", the board's Grill this plan button):
the chat agent checks the plan against the code (missing or too-big tasks, hidden dependencies,
files or functions that don't exist as assumed, callers and tests that break, undecided edge
cases, drift beyond the goal), asks what only the user can decide with `ask_user` (up to five
questions a round, concrete options, its recommendation in the option text), then changes the
tasks, clears settled open questions and writes the scope; another round, or a short summary
when nothing important is open. Standing instructions in `priv/pi/prompts/chat.md`.

**34.2 Scope.** `plans.scope` (migration `add_scope_to_plans`): in scope, out of scope,
assumptions. A new chat tool `update_plan` changes title, goal, findings and scope (never the
status); the board shows the scope under the plan's header; `get_plan` and every tool reply
include it.

**34.3 Answer form.** The question cards are one form: per question option pills (radio) and an
own answer (which wins over a pick); Send answers sends all of them as one message; questions left
unanswered say "(no answer: your call)".

**Status: Phase 34 done (2026-10-01).** Checked live on `bm-sandbox` (served on another port,
headless Chrome): a two-task countVowels plan; Grill this plan made the agent read the CLI and its
tests and ask three questions with recommendations, among them a real scope gap (every utility is
also a textkit command); answered with one pick, one own answer and one left open, it revised
tasks 1 and 2, added `add_vowels_cli`, wrote the scope (in / out / assumptions, shown on the
board) and said the plan was settled. The checkout stayed clean. Fixed during the check: picking
an option scrolled the whole layout (the hidden radio was positioned outside its pill).
