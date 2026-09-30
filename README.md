# BM

BM runs coding agents on your repository under guard. You give it a goal; a planner splits it
into tasks; guarded workers do them one at a time; every change is verified and reviewed before it
is accepted and checkpointed; and your own uncommitted work is never touched.

BM is a Phoenix app (the BEAM side: planning, authorization, scheduling, verification, records,
the web pages) that drives [pi](https://github.com/earendil-works/pi) coding agents over pi's RPC
mode. Its core rule: *the planner proposes work; the BEAM authorizes effects; workers report
outcomes; verification decides acceptance.*

## How a run works

- **One lane.** One mutating worker at a time on one checkout (no worktrees). Before and after
  each attempt BM snapshots the working tree through a private git index, so every change is
  attributed to the attempt that made it.
- **Guarded tools.** Before every edit, write and bash call, the worker's guard asks BM. BM refuses
  git writes, dependency installs, writes outside the checkout and writes to files you had
  uncommitted when the run started. The planner and the reviewer are read-only. What the policy
  cannot see, the snapshot catches afterwards.
- **Verification.** Your verify command (for example `npm test`) and the task's own check must pass;
  then a reviewer reads the diff against your goal and probes edge cases with print-only
  commands. A failed check or a rejection reverts the change and goes back to the planner.
- **Checkpoints, not commits.** Accepted changes stay in your working tree and are recorded under
  `refs/bm/runs/<run>/<n>`. HEAD, your branch and your index are untouched until you choose
  *Commit these changes* (or `mix bm.commit`), which commits exactly the run's files.
- **You decide the rest.** Anything BM could not accept waits for your Keep or Revert. You can
  pause a goal run, undo a single task, revert a whole run, and answer questions a worker's
  extensions ask. Limits (budget, time, silence, repeated calls) and a rule-based supervisor stop
  runaway work; after a restart BM resumes a run when nothing waits for you.

BM is a safety net, not a sandbox: commands run with your privileges.

## Requirements

- Elixir ~> 1.17 with Erlang/OTP, PostgreSQL, git, Node.js
- pi 0.87.1 with the zro provider extension (see `config/config.exs`: model, extension paths and
  pinned versions; a version mismatch stops an agent before it gets work)

## Set up and start

```sh
mix setup                  # dependencies, database, assets
PORT=4001 mix phx.server   # then open http://localhost:4001
```

The terminal commands talk to the running server at `http://127.0.0.1:$PORT` (default 4001), or
at `BM_URL`.

## Use it

**In the browser.** On the Tasks page, choose *Goal* (the planner splits it) or *Single task*,
give the repository path, its verify command and optionally a budget. The run page shows the plan
as a live canvas, each attempt with its diff, verification, review and activity, and the actions
of the moment: Pause, Stop, Keep, Revert, Undo this task, Resume planning, Commit these changes.

**In the terminal.**

```sh
mix bm.goal "Add a /health endpoint with a test" --repo ~/code/app --verify "mix test" --budget 0.5
mix bm.attach BM-12        # follow a run; answer Keep/Revert and approvals here
mix bm.runs                # recent runs (mix bm.runs calc, --limit 50)
mix bm.status BM-12        # one run with its tasks
mix bm.commit BM-12        # commit a finished run's changes on your current branch
```

`mix help bm.<command>` has the details.

The *Chat* page is a plain pi chat with your own pi setup; BM does not control it.

## Development

```sh
mix precommit              # compile with warnings as errors, format, tests
mix test                   # uses a scripted fake pi (test/support/fake_pi.mjs)
mix test --only live       # real pi and model; costs a little
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): design, decisions (D1–D29), safety model
- [docs/FEATURES.md](docs/FEATURES.md): core and optional features, what is done
- [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md): every phase with its status notes
- [docs/TRIALS.md](docs/TRIALS.md): runs on real repositories and what they found
- [docs/BENCHMARK.md](docs/BENCHMARK.md), [docs/BENCHMARK_GOALS.md](docs/BENCHMARK_GOALS.md):
  plain pi against BM
