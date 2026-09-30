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
