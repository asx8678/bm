defmodule Bm.Prompts do
  @moduledoc "Prompts BM sends to its pi agents."

  alias Bm.Runs.Task

  @doc "The prompt for a worker attempting `task`. The worker sees only this, not the plan."
  def worker(%Task{} = task) do
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

    Files you are expected to change:
    #{files}

    Rules:
    - Change only what the task needs. Prefer the declared files; if you must change others,
      say which and why in your summary.
    - Do not use git to change the repository (no add, commit, checkout, stash, reset, ...).
      BM records, verifies and checkpoints your changes itself.
    - Do not start background processes that keep running after you finish.
    - Some files contain the user's uncommitted work and are protected. If a change is refused,
      don't work around it: report the task as blocked and say why.
    - Finish by calling submit_result exactly once: status "done" when the task is complete,
      "blocked" if you cannot complete it without something outside your reach, "failed" if you
      tried and could not. Summarize what you changed in at most five sentences.
    """
  end
end
