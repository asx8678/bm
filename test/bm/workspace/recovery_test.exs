defmodule Bm.Workspace.RecoveryTest do
  use Bm.DataCase, async: false

  alias Bm.Runs
  alias Bm.Workspace.{Coordinator, Git, Recovery}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "readme\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "initial"])
    {:ok, workspace} = Runs.ensure_workspace(repo)
    Runs.update_workspace(workspace, %{verify_command: "true"})
    %{repo: repo, workspace: workspace}
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

  # A process group standing in for a worker's leftovers.
  defp launch_group(script) do
    {exe, args} = Bm.Proc.launch_args("/bin/sh", ["-c", script])
    port = Port.open({:spawn_executable, exe}, [:binary, args: args])
    {:os_pid, pgid} = Port.info(port, :os_pid)
    on_exit(fn -> Bm.Proc.terminate_groups([pgid], 200) end)
    pgid
  end

  # An attempt recorded as running, as a dead coordinator would have left it.
  defp orphaned_attempt!(%{repo: repo, workspace: workspace}, attrs \\ %{}) do
    {:ok, run} = Runs.start_run(workspace, %{goal: "g"})
    {:ok, task} = Runs.create_task(run, %{key: "t", title: "T", goal: "G", mutates: true})
    {:ok, attempt} = Runs.create_attempt(task, %{role: :writer})
    {:ok, tree} = Git.snapshot(repo)
    {:ok, attempt} = Runs.transition_attempt(attempt, :admitted, %{tree_before: tree})

    {:ok, attempt} =
      Runs.transition_attempt(
        attempt,
        :running,
        Map.merge(%{agent_id: "attempt-x", session_epoch: 1, boot_id: Bm.Proc.boot_id()}, attrs)
      )

    {run, attempt}
  end

  test "an attempt that changed files needs reconciliation; its groups end; the run pauses",
       ctx do
    pgid = launch_group("sleep 60")
    verify_pgid = launch_group("sleep 61")
    {run, attempt} = orphaned_attempt!(ctx, %{pgid: pgid})
    Runs.update_attempt_fields(attempt, %{verify: %{"pgid" => verify_pgid}})
    File.write!(Path.join(ctx.repo, "half_done.txt"), "x\n")

    assert [recovered] = Recovery.run()
    assert recovered.status == :needs_reconciliation
    assert recovered.actual_writes == [%{"path" => "half_done.txt", "status" => "added"}]
    assert Bm.Proc.live_groups([pgid, verify_pgid]) == []
    assert Runs.get_run!(run.id).status == :paused
    assert Runs.get_task!(attempt.task_id).status == :failed
  end

  test "an attempt that changed nothing fails as interrupted; the run stays active", ctx do
    {run, _attempt} = orphaned_attempt!(ctx)

    assert [%{status: :failed, error: error}] = Recovery.run()
    assert error =~ "interrupted"
    assert Runs.get_run!(run.id).status == :active
  end

  test "groups recorded in an earlier boot are never signalled", ctx do
    pgid = launch_group("sleep 60")
    orphaned_attempt!(ctx, %{pgid: pgid, boot_id: "an-earlier-boot"})

    assert [%{status: :failed}] = Recovery.run()
    assert Bm.Proc.live_groups([pgid]) == [pgid]
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> receive(after: (20 -> eventually(fun, attempts - 1)))
    end
  end

  describe "a coordinator killed mid-attempt" do
    setup %{repo: repo} do
      opts = [settle_interval: 50, prompt: &Bm.FakePi.prompt/1]
      {:ok, pid} = Coordinator.ensure_started(repo, opts)
      :ok = Coordinator.subscribe(repo)
      on_exit(fn -> Coordinator.stop(repo) end)
      %{coordinator: pid, opts: opts}
    end

    defp run_and_kill!(ctx, steps, written \\ nil) do
      {:ok, attempt} = Coordinator.run_task(ctx.repo, %{title: "t", goal: JSON.encode!(steps)})
      assert_receive {:workspace, _, {:attempt, %{status: :running}, _}}, 10_000

      # Let the scripted write happen before the coordinator dies.
      if written, do: assert(eventually(fn -> File.exists?(Path.join(ctx.repo, written)) end))
      ref = Process.monitor(ctx.coordinator)
      Process.exit(ctx.coordinator, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      attempt
    end

    test "is recovered by its successor; nothing changed frees the lane", ctx do
      attempt = run_and_kill!(ctx, [%{hang: true}])
      {:ok, _pid} = Coordinator.ensure_started(ctx.repo, ctx.opts)

      assert Runs.get_attempt!(attempt.id).status == :failed
      assert %{lane: :free} = Coordinator.state(ctx.repo)
      assert Registry.lookup(Bm.Pi.Registry, "attempt-#{attempt.id}") == []
    end

    test "changes hold the lane and pause the run until the user keeps them", ctx do
      attempt = run_and_kill!(ctx, [%{write: ["half.txt", "x\n"]}, %{hang: true}], "half.txt")
      {:ok, _pid} = Coordinator.ensure_started(ctx.repo, ctx.opts)

      assert Runs.get_attempt!(attempt.id).status == :needs_reconciliation
      assert %{lane: {:held, id}, run_id: run_id} = Coordinator.state(ctx.repo)
      assert id == attempt.id
      assert Runs.get_run!(run_id).status == :paused

      assert :ok = Coordinator.keep(ctx.repo)
      assert Runs.get_run!(run_id).status == :active
      assert {:ok, _} = Coordinator.run_task(ctx.repo, %{title: "next", goal: "[]"})
    end

    test "changes can be reverted instead", ctx do
      attempt = run_and_kill!(ctx, [%{write: ["half.txt", "x\n"]}, %{hang: true}], "half.txt")
      {:ok, _pid} = Coordinator.ensure_started(ctx.repo, ctx.opts)

      assert :ok = Coordinator.revert(ctx.repo)
      refute File.exists?(Path.join(ctx.repo, "half.txt"))
      assert Runs.get_attempt!(attempt.id).status == :reverted
      assert %{lane: :free} = Coordinator.state(ctx.repo)
    end
  end
end
