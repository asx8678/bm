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
| 7 | Planner | 7.1–7.6 | goal → plan → sequential tasks with the fake pi |
| 8 | Plan UI and milestone C gate | 8.1–8.3 | **Milestone C exit gate** (live) + benchmark |

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

---

## Phase 7: planner (fake pi)

**7.1 Plan validation (pure).** `Bm.Plan.validate(proposal, ctx)` with `ctx = %{tasks,
user_owned, root, budget_left, plan_open}`: required fields; `key` format and unique in the run;
`depends_on` refers to existing keys; no cycles; `writes` required and non-empty when `mutates`;
writes inside the root and not user-owned; plan must be open.
Returns `{:ok, task_attrs}` or `{:error, reason}` with a reason the model can act on.
Verify: table-driven tests for each rule, including a three-task cycle.

**7.2 Fake planner.** `fake_pi.mjs` gains `plan:<json>`: sends one `bm:propose_task` dialog per
listed task, then `bm:close_plan`; on each `follow_up` it can run the next scripted wave.
Verify: `pi_test.exs` sees the dialogs in order.

**7.3 Planner session.** `Bm.Runs.start_goal(path, goal)` starts the run with `plan_open = true`,
starts the planner (`Profile.start(…, :planner)`, owner = coordinator) and prompts it with
`Bm.Prompts.planner(goal, workspace)`. `propose_task` → validate → insert task (`queued`) → reply
`accepted` or `rejected` with the reason; `close_plan` → `plan_open = false`.
Verify: a scripted plan with one invalid task yields two queued tasks and one rejection reply;
streamed `propose_task` events alone (without the dialog) create no task.

**7.4 Sequential scheduler.** After every lane change, pick the oldest `queued` task whose
dependencies are `accepted` and admit it (Phase 4). Read-only tasks run in the same lane with the
reader profile. Tasks whose dependency failed become `blocked`.
Verify: tasks `a`, `b(depends a)`, `c` run as `a, b, c` or `a, c, b`, never `b` first; failing `a`
blocks `b`.

**7.5 Result delivery.** When an attempt ends, record a delivery (received), then send the planner
one `follow_up` per batch of finished tasks at its next idle point (delivered). The planner may
propose more tasks (it must reopen: `propose_task` while closed is rejected unless the delivery
reopened planning) and must `close_plan` again. One automatic re-plan per failed task; then the
run fails.
Verify: two tasks finishing while the planner is busy produce one `follow_up`; a duplicate
`submit_result` produces one delivery; a failed task leads to exactly one re-plan message.

**7.6 Run completion.** A run is `done` when the plan is closed and every task is terminal
(`accepted | failed | blocked | cancelled`); `failed` if any required task failed. A planner idle
with the plan open for `plan_timeout` (default 5 min) fails the run.
Verify: tests for done, failed and plan timeout; the workspace lock is released each time.

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

**8.3 Benchmark.** Extend `mix bm.bench` with 3 multi-step goals: plain pi vs BM planner. Record
in `docs/BENCHMARK.md` and decide which optional feature to build first (see FEATURES.md
preconditions).
Verify: results recorded; FEATURES.md updated with the decision.
