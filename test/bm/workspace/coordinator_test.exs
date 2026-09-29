defmodule Bm.Workspace.CoordinatorTest do
  # The coordinator and its jobs use the database from their own processes (shared sandbox).
  use Bm.DataCase, async: false

  alias Bm.Runs
  alias Bm.Workspace.Coordinator

  @moduletag :tmp_dir

  # Worker scripts for the fake pi travel in the task's goal (see fake_pi.mjs, "work:").
  @opts [
    settle_interval: 50,
    settle_timeout: 1_000,
    verify_timeout: 5_000,
    prompt: &__MODULE__.fake_prompt/1
  ]

  def fake_prompt(task), do: "work:" <> task.goal

  setup %{tmp_dir: dir} = context do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "readme\n")
    File.write!(Path.join(repo, "staged.txt"), "v1\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "initial"])
    # The user's uncommitted work: a staged change and an untracked file.
    File.write!(Path.join(repo, "staged.txt"), "user's staged v2\n")
    git!(repo, ["add", "staged.txt"])
    File.write!(Path.join(repo, "notes.txt"), "user's notes\n")

    opts = Keyword.merge(@opts, context[:coordinator] || [])
    {:ok, _pid} = Coordinator.ensure_started(repo, opts)
    :ok = Coordinator.subscribe(repo)
    on_exit(fn -> Coordinator.stop(repo) end)

    %{repo: repo}
  end

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=U", "-c", "user.email=u@example.com" | args],
        cd: repo,
        env: [{"GIT_OPTIONAL_LOCKS", "0"}],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp run!(repo, steps, attrs \\ []) do
    attrs =
      Map.merge(
        %{title: "Test task", goal: JSON.encode!(steps), verify_command: "true"},
        Map.new(attrs)
      )

    {:ok, attempt} = Coordinator.run_task(repo, attrs)
    attempt
  end

  # Waits for the attempt to reach `status`; returns the attempt and the lane.
  defp await_status(status, timeout \\ 10_000) do
    receive do
      {:workspace, _root, {:attempt, %{status: ^status} = attempt, lane}} -> {attempt, lane}
      {:workspace, _root, {:attempt, _other, _lane}} -> await_status(status, timeout)
    after
      timeout -> flunk("attempt did not reach #{status}")
    end
  end

  defp done, do: %{submit: %{status: "done", summary: "done"}}

  describe "coordinator (4.3)" do
    test "one coordinator per checkout; the lane starts free", %{repo: repo} do
      {:ok, pid} = Coordinator.ensure_started(repo)
      assert {:ok, ^pid} = Coordinator.ensure_started(repo <> "/.")
      assert %{lane: :free, phase: nil} = Coordinator.state(repo)
    end

    test "only a repository's top level can be a workspace", %{repo: repo} do
      File.mkdir_p!(Path.join(repo, "sub"))

      assert {:error, {:not_repository_root, _}} =
               Coordinator.ensure_started(Path.join(repo, "sub"))
    end
  end

  describe "admission (4.4)" do
    test "an admitted attempt runs in the checkout and holds the lane", %{repo: repo} do
      attempt = run!(repo, [%{hang: true}])
      {running, {:busy, id}} = await_status(:running)
      assert id == attempt.id
      assert running.tree_before && running.pgid && running.pgid_file && running.boot_id

      assert Bm.Pi.snapshot(running.agent_id).summary.cwd == repo
      assert {:error, :lane_busy} = Coordinator.run_task(repo, %{title: "t", goal: "[]"})

      :ok = Coordinator.cancel(repo)
      await_status(:cancelled)
    end

    test "a failed admission leaves no task, attempt or run behind", %{repo: repo} do
      # BM's private index directory can't be created: the snapshot fails.
      File.write!(Path.join(repo, ".git/bm"), "not a directory")

      assert {:error, {:private_dir, _}} =
               Coordinator.run_task(repo, %{title: "t", goal: "[]", verify_command: "true"})

      assert Repo.all(Runs.Task) == [] and Repo.all(Runs.Attempt) == [] and
               Repo.all(Runs.Run) == []

      assert %{lane: :free, phase: nil} = Coordinator.state(repo)
    end

    test "a workspace needs a verify command", %{repo: repo} do
      assert {:error, :no_verify_command} =
               Coordinator.run_task(repo, %{title: "t", goal: "[]"})
    end
  end

  describe "requests (4.5)" do
    test "a refused command changes nothing and the attempt fails without a result",
         %{repo: repo} do
      run!(repo, [%{bash: "touch made.txt && git commit -am sneaky"}, done()])
      {attempt, lane} = await_status(:failed)

      refute File.exists?(Path.join(repo, "made.txt"))
      assert attempt.error =~ "without submitting a result"
      assert attempt.actual_writes == []
      assert lane == :free
    end

    test "a duplicate submit_result has one effect", %{repo: repo} do
      submit = %{submit: %{status: "done", summary: "once"}, request_id: Ecto.UUID.generate()}
      run!(repo, [%{write: ["a.txt", "a\n"]}, submit, submit])
      {attempt, :free} = await_status(:accepted)

      assert attempt.result == %{"status" => "done", "summary" => "once"}
      assert [_] = Repo.all(from r in Bm.Bridge.Request, where: r.op == "submit_result")
    end

    test "authorizations are recorded without file contents", %{repo: repo} do
      run!(repo, [%{bash: "echo hi > b.txt"}, done()])
      await_status(:accepted)

      assert [%{payload: %{"tool" => "bash", "input" => %{"command" => "echo hi > b.txt"}}}] =
               Repo.all(from r in Bm.Bridge.Request, where: r.op == "authorize")
    end
  end

  describe "settling and attribution (4.6)" do
    @tag coordinator: [settle_timeout: 300]
    test "leftover background processes are waited for, flagged and ended", %{repo: repo} do
      marker = "sleep 60.#{System.unique_integer([:positive])}"
      run!(repo, [%{spawn: marker}, %{write: ["a.txt", "a\n"]}, done()])
      {attempt, :free} = await_status(:accepted)

      assert "leftover_processes" in attempt.flags
      assert {_, 1} = System.cmd("pgrep", ["-f", marker])
      # A clean stop leaves no group file behind (nothing to recover).
      refute File.exists?(attempt.pgid_file)
    end

    test "the write set comes from snapshots, whatever wrote the files", %{repo: repo} do
      run!(repo, [%{bash: "echo x > via_shell.txt"}, %{write: ["via_tool.txt", "y\n"]}, done()],
        writes: ["via_tool.txt"]
      )

      {attempt, :free} = await_status(:accepted)

      assert Enum.sort_by(attempt.actual_writes, & &1["path"]) == [
               %{"path" => "via_shell.txt", "status" => "added"},
               %{"path" => "via_tool.txt", "status" => "added"}
             ]

      assert attempt.flags == ["undeclared_writes"]
    end

    test "a change to a user-owned file fails the attempt and holds the lane", %{repo: repo} do
      # A direct write, as a shell command could do it past the policy.
      run!(repo, [%{write: ["notes.txt", "overwritten\n"]}, done()])
      {attempt, lane} = await_status(:failed)

      assert attempt.error =~ "notes.txt"
      assert "user_owned_writes" in attempt.flags
      assert lane == {:held, attempt.id}
    end

    test "the policy refuses a user-owned file before it is written", %{repo: repo} do
      run!(repo, [%{authorize: %{tool: "write", input: %{path: "notes.txt"}}}, done()])
      {_attempt, :free} = await_status(:failed)
      assert File.read!(Path.join(repo, "notes.txt")) == "user's notes\n"
    end

    test "a task that changes nothing is accepted without verification", %{repo: repo} do
      run!(repo, [done()], verify_command: "false")
      {attempt, :free} = await_status(:accepted)
      assert attempt.verify == %{"skipped" => "no changes"}
      assert attempt.checkpoint_ref == nil
    end

    test "a worker reporting failure fails the attempt", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, %{submit: %{status: "blocked", summary: "stuck"}}])
      {attempt, lane} = await_status(:failed)
      assert attempt.error =~ "blocked: stuck"
      assert lane == {:held, attempt.id}
    end
  end

  describe "verification (4.7)" do
    test "a failing verify command holds the lane with its output", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()], verify_command: "echo broken; exit 3")
      {attempt, lane} = await_status(:held)

      assert attempt.error == "verify_failed"
      assert %{"exit" => 3, "output" => "broken\n"} = attempt.verify
      assert lane == {:held, attempt.id}
    end

    @tag coordinator: [verify_timeout: 300]
    test "a verify command past its timeout is ended with its whole group", %{repo: repo} do
      marker = "sleep 31.#{System.unique_integer([:positive])}"
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()], verify_command: "#{marker} & #{marker}")
      {attempt, _lane} = await_status(:held)

      assert attempt.error == "verify_timeout"
      assert {_, 1} = System.cmd("pgrep", ["-f", marker])
    end
  end

  describe "verification side effects (review)" do
    test "files the verify command changes belong to the attempt and its checkpoint",
         %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()], verify_command: "echo generated > gen.txt")
      {attempt, :free} = await_status(:accepted)

      assert Enum.map(attempt.actual_writes, & &1["path"]) |> Enum.sort() == ["a.txt", "gen.txt"]
      assert "verify_changed_files" in attempt.flags
      assert git!(repo, ["cat-file", "-p", "#{attempt.checkpoint_ref}:gen.txt"]) == "generated"
    end

    test "a verify command that changes the user's files holds the lane", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()],
        verify_command: "echo reformatted > notes.txt"
      )

      {attempt, lane} = await_status(:held)

      assert attempt.error =~ "notes.txt"
      assert lane == {:held, attempt.id}
    end

    test "verify output that is not valid UTF-8 is stored", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()],
        verify_command: "printf 'ok \\377\\376 bytes\\n'; exit 1"
      )

      {attempt, _lane} = await_status(:held)
      assert String.valid?(attempt.verify["output"])
      assert attempt.verify["output"] =~ "ok"
    end
  end

  describe "read-only tasks" do
    test "run with the reader profile and are accepted without changes", %{repo: repo} do
      run!(repo, [done()], mutates: false)
      {attempt, :free} = await_status(:accepted)
      assert attempt.role == :reader
    end

    test "fail when files change", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()], mutates: false)
      {attempt, _lane} = await_status(:failed)
      assert attempt.error =~ "read-only"
    end
  end

  describe "checkpoints (4.8)" do
    test "an accepted attempt is checkpointed; the user's git state is untouched", %{repo: repo} do
      cached = git!(repo, ["diff", "--cached"])
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()])
      {attempt, :free} = await_status(:accepted)

      %{run_id: run_id} = Coordinator.state(repo)
      assert attempt.checkpoint_ref == "refs/bm/runs/#{run_id}/1"
      assert git!(repo, ["cat-file", "-p", "#{attempt.checkpoint_ref}:a.txt"]) == "a"
      assert git!(repo, ["diff", "--cached"]) == cached
      assert git!(repo, ["log", "--oneline"]) =~ "initial"
      refute git!(repo, ["log", "--oneline"]) =~ "BM run"

      # The next checkpoint builds on the previous one.
      run!(repo, [%{write: ["b.txt", "b\n"]}, done()])
      {second, :free} = await_status(:accepted)
      assert second.checkpoint_ref == "refs/bm/runs/#{run_id}/2"

      assert git!(repo, ["rev-parse", "#{second.checkpoint_ref}^"]) ==
               git!(repo, ["rev-parse", attempt.checkpoint_ref])
    end

    test "keep accepts a held attempt as unverified and frees the lane", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()], verify_command: "false")
      {held, {:held, _}} = await_status(:held)

      assert :ok = Coordinator.keep(repo)
      {kept, :free} = await_status(:accepted)
      assert kept.id == held.id
      assert "kept" in kept.flags
      assert git!(repo, ["log", "-1", "--format=%s", kept.checkpoint_ref]) =~ "kept, unverified"
      assert {:error, :nothing_held} = Coordinator.keep(repo)
    end
  end

  describe "cancel (4.9)" do
    test "cancelling before any change frees the lane", %{repo: repo} do
      run!(repo, [%{hang: true}])
      await_status(:running)
      :ok = Coordinator.cancel(repo)

      {attempt, :free} = await_status(:cancelled)
      assert attempt.actual_writes == []
      assert Runs.get_task!(attempt.task_id).status == :cancelled
    end

    test "cancelling after a change holds the lane with that change", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, %{hang: true}])
      await_status(:running)
      # Let the write happen before cancelling.
      assert eventually(fn -> File.exists?(Path.join(repo, "a.txt")) end)
      :ok = Coordinator.cancel(repo)

      {attempt, lane} = await_status(:cancelled)
      assert attempt.actual_writes == [%{"path" => "a.txt", "status" => "added"}]
      assert lane == {:held, attempt.id}
      assert :ok = Coordinator.keep(repo)
      assert %{lane: :free} = Coordinator.state(repo)
    end

    test "cancel with nothing running is refused", %{repo: repo} do
      assert {:error, :nothing_running} = Coordinator.cancel(repo)
    end
  end

  describe "budget (5.1)" do
    test "a message crossing the budget cancels the attempt; admission then refuses",
         %{repo: repo} do
      run!(repo, [%{message: "thinking"}, %{hang: true}], budget_usd: 0.002)
      {attempt, :free} = await_status(:cancelled)

      assert attempt.error == "cancelled by BM: budget"
      %{run_id: run_id} = Coordinator.state(repo)
      assert %{spent_usd: 0.003} = Runs.get_run!(run_id)

      assert {:error, :budget_exhausted} =
               Coordinator.run_task(repo, %{title: "t", goal: "[]"})
    end

    test "usage without a cost counts as unknown, never as 0", %{repo: repo} do
      run!(repo, [%{message: "no cost", cost: false}, %{write: ["a.txt", "a\n"]}, done()])
      await_status(:accepted)

      %{run_id: run_id} = Coordinator.state(repo)
      # The final answer costs 0.003; the first message came without a cost.
      assert %{spent_usd: 0.003, spent_unknown: 1} = Runs.get_run!(run_id)
    end
  end

  describe "time limits (5.2)" do
    @tag coordinator: [stall_timeout: 200]
    test "a worker without events is cancelled as stalled", %{repo: repo} do
      run!(repo, [%{hang: true}])
      {attempt, _lane} = await_status(:cancelled)
      assert attempt.error == "cancelled by BM: stall"
    end

    @tag coordinator: [stall_timeout: 200]
    test "a running tool is not a stall", %{repo: repo} do
      run!(repo, [%{bash: "sleep 0.6"}, done()])
      assert {_attempt, :free} = await_status(:accepted)
    end

    @tag coordinator: [max_duration: 300]
    test "a busy worker is cancelled after the maximum duration", %{repo: repo} do
      run!(repo, [%{busy: 5_000}])
      {attempt, _lane} = await_status(:cancelled)
      assert attempt.error == "cancelled by BM: max_duration"
    end
  end

  describe "revert (5.3)" do
    test "reverts a held attempt and frees the lane", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, %{write: ["README.md", "changed\n"]}, done()],
        verify_command: "false"
      )

      {held, {:held, _}} = await_status(:held)

      assert :ok = Coordinator.revert(repo)
      {reverted, :free} = await_status(:reverted)
      assert reverted.id == held.id
      refute File.exists?(Path.join(repo, "a.txt"))
      assert File.read!(Path.join(repo, "README.md")) == "readme\n"
      assert Runs.get_task!(held.task_id).status == :cancelled
    end

    test "reverts the latest accepted attempt", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()])
      await_status(:accepted)

      assert :ok = Coordinator.revert(repo)
      await_status(:reverted)
      refute File.exists?(Path.join(repo, "a.txt"))
      assert {:error, :nothing_to_revert} = Coordinator.revert(repo)
    end

    test "refuses when a file changed since, and changes nothing", %{repo: repo} do
      run!(repo, [%{write: ["a.txt", "a\n"]}, done()], verify_command: "false")
      {held, {:held, _}} = await_status(:held)
      File.write!(Path.join(repo, "a.txt"), "the user's edit\n")

      assert {:error, {:changed_since, ["a.txt"]}} = Coordinator.revert(repo)
      assert File.read!(Path.join(repo, "a.txt")) == "the user's edit\n"
      assert %{lane: {:held, id}} = Coordinator.state(repo)
      assert id == held.id
    end

    test "is refused while an attempt runs", %{repo: repo} do
      run!(repo, [%{hang: true}])
      await_status(:running)
      assert {:error, :attempt_running} = Coordinator.revert(repo)
      Coordinator.cancel(repo)
      await_status(:cancelled)
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> receive(after: (20 -> eventually(fun, attempts - 1)))
    end
  end
end
