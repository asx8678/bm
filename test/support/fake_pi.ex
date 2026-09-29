defmodule Bm.FakePi do
  @moduledoc """
  Helpers for tests that run workers on the scripted fake pi (`test/support/fake_pi.mjs`).
  """

  @doc "Coordinator `:prompt` option: the task's goal holds the worker script (JSON steps)."
  def prompt(task), do: "work:" <> task.goal
end
