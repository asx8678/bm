# BM trials on real code (plan phase 11)

Supervised goal runs on a real repository, started from the Tasks page and watched on the run
page. Findings and fixes are recorded here and in IMPLEMENTATION_PLAN.md (Phase 11 status).

## Setup (11.1)

- Target: a clone of this repository at `/tmp/bm-trial` (124 files), never the checkout the dev
  server runs from. `deps/` and `_build/` copied in (ignored by git, so not in BM's snapshots)
  and compiled once.
- Verify command: `mix compile --warnings-as-errors`. Budget per goal $0.30–0.50.
- User's uncommitted work: an appended line in `README.md`.
- Model: zro/glm-5.3 for planner and workers.

## Goals (11.2), 2026-09-30

| Run | Goal | Tasks | Waves | Outcome | Time | Cost |
|---|---|---|---|---|---|---|
| 54 | `mix bm.runs` task listing recent runs | 1 | 1 | done, accepted | 19 s | $0.087 |
| 55 | BM-<id> labels: `label/1`, run header, page title, runs list | 3 (2 depend on the 1st) | 1 | done, 3 accepted | 69 s | $0.156 |
| 56 | Document `mix bm.runs` in README.md (the user's dirty file) | 0 | 1 | done (**wrong**, see F1) | – | $0.022 |
| 57 | Same as 56, after the fix | 0 | 1 | failed: "the planner could not plan the goal: …README.md has the user's uncommitted changes…" | – | ≈$0.02 |

Checked by hand after the runs: the new task prints the runs (`mix bm.runs`); the label changes
are small and idiomatic (`label/1` with a unit test, used in the header, title and list); the
user's `README.md` line is intact after all four runs; no attempt was held, flagged or failed.

## Findings

- **F1 (fixed, 11.3):** a goal BM had to refuse (its only task needed the user's dirty file, so
  the proposal was rejected) ended **done** with "the planner closed the plan without tasks".
  Now a task-less plan after rejections ends **failed** with the planner's summary as the reason;
  done only when the planner proposed nothing (it judged nothing needs doing). The run's
  `planner.rejected` counts rejected proposals.
- **F2 (noted):** the planner made each task's `check` a focused `mix test <file>`. In this repo the
  tests use a database shared with the main checkout's test environment, so a trial's checks
  touch that database. BM is not a sandbox (it never claims to be); checks and verify commands run
  with the repository's own resources. For BM-on-BM trials, don't run the main checkout's suite
  at the same time.
- **Safety held:** the user's uncommitted `README.md` was never changed; every accepted change was
  checkpointed; the lane was never held.
- **Cost and time** on real code are close to the toy goals: $0.02–0.16 per goal, 19–69 s.

## Phase 14 (2026-09-30)

- Run 68 (via the UI, after a resume): `Bm.Runs.count_runs/0` — reviewer approved with a specific
  reason ($0.027 for the review), run done ($0.17 total).
- Run 69/70 (via `mix bm.goal`): `Bm.Runs.count_tasks/0` needed `lib/bm/runs.ex`, which held run 68's
  accepted but uncommitted change. **F3 (fixed):** the planner correctly refused, but the run ended
  "done"; now `close_plan(blocked: true)` → failed with the planner's reason (run 70).
- **Note for users:** BM never commits. Commit or stash accepted changes before the next goal that
  touches the same files, or BM will treat them as your uncommitted work and leave them alone.

## Sandbox repository (plan 17, 2026-09-30)

At the user's request, a new repository made for trying BM: `~/projects/bm-sandbox`, a small
dependency-free Node package (`slugify`, `wordCount`, tests with `node --test`). Verify command:
`node --test`. Goals started with `mix bm.goal`, each accepted change committed with
`mix bm.commit`.

| Run | Goal | Tasks | Outcome | Cost |
|---|---|---|---|---|
| 77 | Fix `wordCount` for runs of whitespace, tabs, newlines, surrounding whitespace | 1 | done, review approved; committed | $0.035 |
| 78 | `truncate(text, max)` at a word boundary with an ellipsis, plus a `bin/textkit.js` CLI and README section | 2 (CLI after truncate) | done, both reviews approved; committed | $0.095 |
| 79 | Bug found by hand in 78: `truncate('abcdef', 0)` returned 6 characters; fix it and reject negative or non-integer `max` | 1 | done, review approved; committed | $0.038 |

- Every change was checked by hand: code read, the CLI run on sample input (bad usage exits 1),
  tests 2 → 19 → 21, all passing.
- **Finding:** run 78's `truncate` passed its tests, the verify command and the reviewer, but broke
  its own contract for `max = 0`. BM's gates only catch what the tests and the reviewer think of;
  edge cases still need a human look or a goal that names them. Run 79 fixed it cleanly.
- Total: 3 goals, 4 tasks, $0.17, no attempt held or failed; HEAD moved only through `mix bm.commit`.
