defmodule Bm.WorkspaceFixtures do
  @moduledoc """
  Throwaway git repositories with the user's uncommitted work in them (a staged change and an
  untracked file), and coordinators that run the fake pi's scripted workers.
  """

  alias Bm.Workspace.Coordinator

  @coordinator_opts [
    settle_interval: 50,
    settle_timeout: 1_000,
    verify_timeout: 5_000,
    prompt: &Bm.FakePi.prompt/1
  ]

  @doc "Creates a repository under `dir` and returns its path."
  def repo!(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "readme\n")
    File.write!(Path.join(repo, "staged.txt"), "v1\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "initial"])
    File.write!(Path.join(repo, "staged.txt"), "user's staged v2\n")
    git!(repo, ["add", "staged.txt"])
    File.write!(Path.join(repo, "notes.txt"), "user's notes\n")
    repo
  end

  @doc "Starts the repository's coordinator with the fake worker's prompt."
  def start_coordinator!(repo, opts \\ []) do
    {:ok, _pid} = Coordinator.ensure_started(repo, Keyword.merge(@coordinator_opts, opts))
    ExUnit.Callbacks.on_exit(fn -> Coordinator.stop(repo) end)
    repo
  end

  def git!(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=U", "-c", "user.email=u@example.com" | args],
        cd: repo,
        env: [{"GIT_OPTIONAL_LOCKS", "0"}],
        stderr_to_stdout: true
      )

    String.trim(out)
  end
end
