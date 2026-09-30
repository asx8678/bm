defmodule Bm.FakePi do
  @moduledoc """
  Helpers for tests that run workers on the scripted fake pi (`test/support/fake_pi.mjs`).
  """

  @doc """
  Coordinator `:prompt` option: the task's goal holds the worker script (JSON steps). The
  dependency context of a real prompt is ignored.
  """
  def prompt(task, _dependencies \\ []), do: "work:" <> task.goal

  @doc "Planner `:prompt` option: the run's goal holds the planner script (JSON list of waves)."
  def planner_prompt(goal, _context), do: "plan:" <> goal

  @doc "A planner script (see `plan:` in fake_pi.mjs) as a run goal."
  def plan(waves), do: JSON.encode!(waves)
end
