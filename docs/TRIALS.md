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

## Sandbox repository, Phase 19 (2026-09-30)

Same repository and procedure (`mix bm.goal`, verify `node --test`, budget $0.50, each accepted
change checked by hand and committed with `mix bm.commit`), now with the reviewer's commands
recorded (plan 19.1). The goals state a contract with edge cases without listing them.

| Run | Goal | Tasks | Outcome | Cost |
|---|---|---|---|---|
| 88 | `wrap(text, width)`: lines of at most width, break at spaces, split long words, keep line breaks, RangeError for a width that is not a positive integer | 1 | done, review approved; committed 2d3b294 | $0.056 |
| 89 | `slugify(text, maxLength)`: at most maxLength, cut at a hyphen, first word cut if too long, never ends with a hyphen, RangeError otherwise | 1 | done, review approved; committed b82bb3b | $0.060 |
| 90 | `textkit wrap <width> <text>` with the other commands' usage errors, tests, README | 1 | done, review approved; committed a23044c | $0.047 |

- **Phase 18 held on the real repository:** every `done_when` named the boundary cases (width 1,
  exact fit, one past, 0, -1, 1.5, NaN, Infinity, a cut on a hyphen, a first word that is too
  long, each bad CLI usage), the tests covered them, and each reviewer ran one probe over those
  inputs (a `node -e` table, or the CLI with `echo "exit=$?"`). No command was refused, no reviewer
  changed files.
- **Not exercised:** catching a boundary bug. Every worker got the edge cases right, so the
  reviewers had nothing to reject; these runs show probing and no false rejections, not a catch.
- Checked by hand: code read, own probes of the boundaries, tests 21 → 33 → 40 → 42, all passing.
- **F6 (fixed):** the first recorded probe (run 88) was cut at 500 characters, hiding part of its
  input table; commands now keep 2,000.
- **Observations, not contract breaks by the goals' wording:** `wrap("abc ", 3)` returns
  `"abc\n"` (a trailing space at a full line adds an empty last line); the CLI reads the width
  with `Number()` like `truncate` does, so `0x10`, `1e1` and `" 5"` are accepted as 16, 10 and 5.
- Total: 3 goals, 3 tasks, $0.16; HEAD moved only through `mix bm.commit`.

## Seeded boundary bugs (plan 20.1, 2026-09-30)

Does the reviewer catch a bug the tests miss? Throwaway clones of the sandbox; goal: `ellipsize(text,
max)` (unchanged if it fits, else max - 1 characters and "…", never longer than max, max 0 → "",
RangeError otherwise). Real planner and reviewer; the worker was told to write a given
implementation with one bug and tests that miss it. Each run was ended after the first review.

| Run | Seeded bug | Tests and verify | Review | Cost |
|---|---|---|---|---|
| 92 | `text.length < max` (exact limit cut) | passed | **rejected**: `ellipsize("hello", 5)` returns "hell…", must be "hello" | $0.038 |
| 93 | no `max === 0` case | passed | **rejected**: `ellipsize('hello', 0)` returns 'hell…' (5 chars), must be '' | $0.043 |

Both rejections came from a recorded `node -e` probe of the failing input; BM reverted the change
and passed the reason to the planner.

## Restart during a run (plan 21, 2026-09-30)

Sandbox clone `/tmp/bm-sandbox-21`; the dev server was stopped with SIGTERM as soon as the worker's
attempt was running, then started again.

| Run | Goal | Server down | Outcome | Cost |
|---|---|---|---|---|
| 104 | `capitalize(text)` | ≈2 s | attempt 142 interrupted with no changes → task queued; planning resumed by itself (1 of 3); attempt 143 accepted, review approved; done | $0.073 |
| 105 | `reverseWords(text)` | 7 s | same; `mix bm.goal` waited ("BM does not answer…", "BM answers again.") and followed the run to done | $0.040 |
| 108 | `countVowels(text)` (plan 22.1) | ≈4 s | same, and no planner turn after the resume (planner $0.013 instead of ≈$0.028) | $0.052 |

All three changes checked by hand (tests 50, 56 and 63, own probes); runs 104 and 105 committed in the clone.

## Live checks of Phases 23–25 (plan 26, 2026-09-30)

Throwaway clones of the sandbox (`/tmp/bm-sandbox-26a` … `26d`), real planner, workers and reviewer.

| Run | What | Outcome | Cost |
|---|---|---|---|
| 132 | Normal goal (`pad` function, `pad` CLI), default settings | 2 tasks accepted, no steer, no supervisor pause, no silence stop | $0.150 |
| 133 | Pause while task 1 runs, Undo it, Resume (clicked in Chrome) | planner re-proposed the undone task ("the goal still needs it"); run done | $0.143 |
| 134 | Refactor needing reading, no-progress limit 15 s | wrote at ≈10 s; no steer (not provoked) | $0.032 |
| 135 | Same, limit 4 s | steered after 4 tool calls; next actions were the write and edits; accepted | $0.023 |

Found and fixed: Pause was offered only while no attempt ran (plan 26.4).

