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

## A project of the user's: kiro-fabric (plan 15.3, 2026-09-30)

Clone of `~/projects/kiro-fabric` (TypeScript, 311 files, clean working tree; `factory` was being
worked on and `triagee` had uncommitted work, so they were not used) at `/tmp/bm-trial-kf`,
`node_modules` linked from the original and excluded locally, a stand-in user edit in README.md.
Verify command: `npx tsc --noEmit && npx tsc --project tsconfig.scripts.json` (≈3 s).

| Run | Goal | Started from | Tasks | Outcome | Time | Cost |
|---|---|---|---|---|---|---|
| 71 | `largestFittingInteger` throws RangeError for non-finite/non-integer bounds, with a test | `mix bm.goal` | 1 | done; check `vitest run tests/bounded-search.test.ts` passed; review approved | ≈20 s | $0.055 |
| 72 | "make the config loading errors friendlier", sharpened with Review goal | web page | 2 | done; review approved | 3 min 39 s | $0.433 |

- Run 71: a single `Number.isInteger` guard with a clear message and a focused test; the file's 4
  tests pass. Idiomatic for the codebase.
- Run 72: the goal review named the right functions in `src/config.ts` and asked four sharp
  questions, one noticing that the tests assert exact message substrings. The change adds the
  config file path, the offending value and the expected type to the messages (≈100 lines); the 19
  configuration tests and the typecheck pass.
- **F4 (fixed):** the planner added a read-only task `build_verify` whose only point was its check
  (`pnpm run build`), but a task that changed no files was accepted without running verification,
  so the build never ran. Now a no-change task with a check runs the check alone (the verify
  command still skipped); a failing check fails it (checked with the fake pi: `true` → accepted,
  `exit 3` → failed with the check's reason).
- The user's README edit was untouched in both runs; the original repository was never changed.

## First real use: ~/projects/kiro-fabric itself (plan 17, 2026-09-30)

Not a clone: BM worked in the user's real checkout (working tree clean before; `knip` reported
nothing unused, no TODOs, so the first goal was documentation-only). Verify command: the
project's typecheck.

| Run | Goal | Tasks | Outcome | Time | Cost |
|---|---|---|---|---|---|
| 76 | TSDoc comments on the three exports of `src/async-settlement.ts`, no code changes | 1 | done; check `pnpm run build` passed; review approved | 1 min 23 s | $0.112 (planner $0.026, review $0.013) |

- The change: 15 comment lines added, 0 removed, in the file's `/** … */` style. HEAD untouched,
  nothing staged; checkpoint `refs/bm/runs/76/1` in the repository. Left uncommitted for the user
  (Commit / `mix bm.commit BM-76`, or Revert).
- **F5 (fixed): the worker repaired the environment.** The planner's check `pnpm run build` first
  failed because pnpm found `node_modules` out of step with the lockfile; the worker then spent a
  minute on environment commands and ran `CI=true pnpm install --frozen-lockfile`, which reinstalled
  the user's `node_modules` (lockfile unchanged, so the same locked versions). BM allowed it and
  recorded nothing: `node_modules` is ignored by git, outside BM's snapshots. `dist/` was rebuilt by
  the check (expected for a build check). Fixed: the policy refuses dependency-changing commands in
  every mode (npm/pnpm/yarn/bun install·add·remove·update, pip/uv/poetry/pipenv, bundle/gem,
  cargo add·install, mix deps.*, go get/install, brew, apt) with a reason telling the model to report
  the task blocked and name the command; builds and tests stay allowed. The worker prompt says not
  to repair the environment but to report it. Checked by calling the policy on sample commands.
