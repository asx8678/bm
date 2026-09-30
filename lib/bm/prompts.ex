defmodule Bm.Prompts do
  @moduledoc "Prompts BM sends to its pi agents: workers, and the planner of a goal run."

  alias Bm.Runs.Task

  @doc """
  The prompt for a worker attempting `task`. The worker sees only this, not the plan; for each
  accepted dependency it gets the title, the summary and the files changed (plan 7.5, from
  `Bm.Runs.dependency_context/1`).
  """
  def worker(%Task{} = task, dependencies \\ []) do
    files =
      case task.writes do
        [] -> "Not declared."
        writes -> Enum.map_join(writes, "\n", &"- #{&1}")
      end

    """
    You are a BM worker. Complete exactly one task in this repository, then report.

    Task: #{task.title}

    Goal:
    #{task.goal}

    Done when:
    #{task.done_when || "The goal is achieved."}
    #{check_section(task)}
    Files you are expected to change:
    #{files}
    #{dependency_section(dependencies)}
    Rules:
    - Change only what the task needs. Prefer the declared files; if you must change others,
      say which and why in your summary.
    - Do not use git to change the repository (no add, commit, checkout, stash, reset, ...).
      BM records, verifies and checkpoints your changes itself.
    - Do not start background processes that keep running after you finish.
    - Some files contain the user's uncommitted work and are protected. If a change is refused,
      don't work around it: report the task as blocked and say why.
    - If the task is genuinely ambiguous (two reasonable readings that lead to different code),
      call ask_planner once with a specific question. Read the repository first; don't ask
      what you can find out yourself.
    - Finish by calling submit_result exactly once: status "done" when the task is complete,
      "blocked" if you cannot complete it without something outside your reach, "failed" if you
      tried and could not. Summarize what you changed in at most five sentences.
    """
  end

  defp check_section(%Task{check: nil}), do: ""

  defp check_section(%Task{check: check}) do
    "\nBM runs this command after your work; it must pass:\n    #{check}\n"
  end

  defp dependency_section([]), do: ""

  defp dependency_section(dependencies) do
    items =
      Enum.map_join(dependencies, "\n", fn dep ->
        files = if dep.writes == [], do: "no files", else: Enum.join(dep.writes, ", ")
        "- #{dep.title} (#{dep.key}): #{dep.summary || "no summary"} Changed: #{files}."
      end)

    "\nDone before this task (already in the repository):\n#{items}\n"
  end

  @doc """
  The prompt of the reviewer of an attempt (plan 14.1, D25): the task, its accepted
  dependencies, and the diff that would be checkpointed.
  """
  def reviewer(%Task{} = task, dependencies, diff) do
    """
    You are a BM reviewer. A worker changed this repository for the task below; the workspace
    verify command #{if task.check, do: "and the task's check ", else: ""}already passed. Decide
    whether the change does what the task asks.

    Task: #{task.title}

    Goal:
    #{task.goal}

    Done when:
    #{task.done_when || "The goal is achieved."}
    #{check_section(task)}#{dependency_section(dependencies)}
    The change (unified diff):
    #{diff}

    Rules:
    - Reject only for concrete problems: the change does not do the task or does only part of
      it, it is clearly broken, or it changes files the task has no reason to touch. Not for
      style, naming or taste.
    - You may read files for context. Do not run the project's test suite or the verify command;
      they already ran.
    - Finish by calling submit_result exactly once: status "done" to approve, "failed" to reject.
      In the summary give the reason in one to three sentences (for a rejection: what is wrong
      and where).
    """
  end

  @doc """
  The first prompt of a goal run's planner. `context`: `:root`, `:verify_command`,
  `:user_owned` (paths the plan must not change).
  """
  def planner(goal, context) do
    """
    You are the BM planner for this repository (#{context.root}). Turn the goal below into a
    small plan of tasks for worker agents, then close the plan.

    Goal:
    #{goal}
    #{files_section(context[:files])}
    How BM works:
    - Look around first (read, grep, find, ls, and read-only bash such as tests or git log).
      You cannot change files yourself; BM refuses writes and pauses the run if files change.
    - Propose the whole plan in ONE propose_plan call, tasks in dependency order, and pass
      close_summary if the plan is complete: that also closes it. BM validates every task and
      answers per task; fix a rejected task with propose_task, then call close_plan.
    - Each task is done by a separate worker that sees only that task and short summaries of
      the tasks it depends on, never this conversation. Make every goal self-contained.
    - Tasks run one at a time, in order of `depends_on`. Keep tasks small; one to four tasks
      are enough for most goals.
    - `writes` must list every file the task creates or changes (required when mutates is
      true). Never plan changes to these files with the user's uncommitted work:
    #{user_owned(context.user_owned)}
    - After every task BM runs the verify command `#{context.verify_command}`, and the task's
      optional `check` command (use it to make done_when executable, e.g. a focused test). If
      the check fails, BM reverts that task's changes and reports back to you, and the task can
      be proposed once more; a second failure fails the run. So a check must be right: write it
      as plain shell, prefer running a test the task itself adds, and never hard-code an
      expected value you have not worked out exactly. (A failing verify command, by contrast,
      stops the run until the user decides.)
    - Once the plan is closed (close_summary or close_plan), BM runs the tasks. A worker may
      ask you one question about an unclear task; then just answer it briefly.
    - If the goal can't be reached at all (for example it needs a file with the user's
      uncommitted work), propose nothing and call close_plan with blocked: true and the reason.
      Use blocked: false with no tasks only when the goal is already met. It comes back to you only if a task fails, is blocked, or changes
      something unexpected; if every task succeeds, the run finishes. So close the plan only
      when it is complete.
    """
  end

  @doc """
  The follow_up that reports finished tasks to the planner (plan 7.6). `results`: maps with
  `:task`, `:status`, `:summary`, `:writes`, `:error`, `:verify_tail`. `run_state` lists the
  tasks still queued.
  """
  def planner_delivery(results, queued) do
    lines =
      Enum.map_join(results, "\n", fn r ->
        base = "- #{r.task.key} (#{r.task.title}): #{r.status}."
        summary = if r.summary, do: " Worker: #{r.summary}", else: ""
        files = if r.writes != [], do: " Changed: #{Enum.join(r.writes, ", ")}.", else: ""
        error = if r.error, do: " Problem: #{r.error}.", else: ""

        check =
          if r.task.check && r.status != :accepted && r.error && r.error =~ "check",
            do: " Its check was: #{r.task.check}",
            else: ""

        tail =
          if r.verify_tail, do: "\n  Verification output (end):\n  #{r.verify_tail}", else: ""

        base <> summary <> files <> error <> check <> tail
      end)

    retry =
      if Enum.any?(results, &(&1.status != :accepted)),
        do:
          "\nA task that did not succeed may be proposed once more with the same key (it " <>
            "replaces the failed one); tasks that depended on it wait for it. When a task's " <>
            "check failed or the reviewer rejected it, BM has already reverted that task's " <>
            "changes, so the files are as before it: decide whether the work or the check was " <>
            "wrong (a rejection says what the reviewer found), and fix that one. If " <>
            "the goal can't be reached, say why in close_plan.",
        else: ""

    still =
      if queued == [],
        do: "No tasks are waiting.",
        else: "Still waiting: #{Enum.map_join(queued, ", ", & &1.key)}."

    """
    BM results:
    #{lines}
    #{still}#{retry}

    Planning is open again. Propose further tasks only if the goal needs them, then call
    close_plan (also when nothing more is needed).
    """
  end

  @doc "Sent once per wave when the planner stops with the plan still open and nothing to run."
  def planner_reminder do
    """
    The plan is still open and no task is waiting. Propose the remaining tasks, or call
    close_plan if the goal needs nothing more.
    """
  end

  @doc "The prompt of a new planner session that resumes a paused goal run."
  def planner_resume(goal, context, tasks) do
    done =
      case tasks do
        [] ->
          "No tasks yet."

        tasks ->
          Enum.map_join(tasks, "\n", fn t ->
            "- #{t.key} (#{t.title}): #{t.status}#{if t.revision > 1, do: ", re-planned", else: ""}"
          end)
      end

    planner(goal, context) <>
      """

      This run was interrupted and is resumed in a new session. Tasks so far:
      #{done}
      Continue from here: propose what is still missing (or re-propose a task that did not
      succeed, once), then call close_plan.
      """
  end

  defp files_section({[_ | _] = files, more}) do
    rest = if more > 0, do: "\n(and #{more} more)", else: ""
    "\nFiles in the repository:\n" <> Enum.join(files, "\n") <> rest <> "\n"
  end

  defp files_section(_none), do: ""

  defp user_owned([]), do: "      (none)"
  defp user_owned(paths), do: Enum.map_join(paths, "\n", &"      - #{&1}")
end
