defmodule Bm.RunsTest do
  use Bm.DataCase, async: true

  alias Bm.Runs
  alias Bm.Runs.{Attempt, Run, Task, Workspace}

  @moduletag :tmp_dir

  defp workspace!(%{tmp_dir: dir}) do
    {:ok, workspace} = Runs.ensure_workspace(dir)
    workspace
  end

  defp task_attrs(key \\ "add_health"),
    do: %{key: key, title: "Add health", goal: "Add a health endpoint.", mutates: true}

  defp attempt!(ctx) do
    {:ok, run} = Runs.start_run(workspace!(ctx), %{goal: "g"})
    {:ok, task} = Runs.create_task(run, task_attrs())
    {:ok, attempt} = Runs.create_attempt(task, %{role: :writer})
    attempt
  end

  describe "workspaces" do
    test "the path is canonical, so a symlinked path is the same workspace", ctx do
      link = Path.join(System.tmp_dir!(), "bm-link-#{System.unique_integer([:positive])}")
      File.ln_s!(ctx.tmp_dir, link)
      on_exit(fn -> File.rm(link) end)

      {:ok, a} = Runs.ensure_workspace(ctx.tmp_dir)
      {:ok, b} = Runs.ensure_workspace(link)
      assert a.id == b.id
      assert {:ok, a.path} == Runs.canonical_path(ctx.tmp_dir)
    end

    test "a missing directory is refused", ctx do
      assert {:error, {:not_a_directory, _}} =
               Runs.ensure_workspace(Path.join(ctx.tmp_dir, "missing"))
    end

    test "the path must be absolute" do
      refute Workspace.changeset(%Workspace{}, %{path: "relative"}).valid?
    end
  end

  describe "run lifecycle" do
    test "one unfinished run per workspace; finishing releases the workspace", ctx do
      workspace = workspace!(ctx)
      assert {:ok, %Run{status: :active} = run} = Runs.start_run(workspace, %{goal: "one"})
      assert {:error, :workspace_busy} = Runs.start_run(workspace, %{goal: "two"})
      assert Runs.get_unfinished_run(workspace).id == run.id

      assert {:ok, %Run{status: :done, finished_at: %DateTime{}}} = Runs.finish_run(run, :done)
      assert Runs.get_unfinished_run(workspace) == nil
      assert {:ok, _} = Runs.start_run(workspace, %{goal: "two"})
    end

    test "a paused run still holds the workspace", ctx do
      workspace = workspace!(ctx)
      {:ok, run} = Runs.start_run(workspace, %{goal: "one"})
      {:ok, paused} = Runs.pause_run(run)

      assert {:error, :workspace_busy} = Runs.start_run(workspace, %{goal: "two"})
      assert {:ok, %Run{status: :active}} = Runs.resume_run(paused)
      assert {:ok, %Run{status: :cancelled}} = Runs.cancel_run(run)
    end

    test "a run needs a goal and a positive budget", ctx do
      workspace = workspace!(ctx)
      assert {:error, changeset} = Runs.start_run(workspace, %{goal: ""})
      assert %{goal: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Runs.start_run(workspace, %{goal: "g", budget_usd: 0})
      assert %{budget_usd: [_]} = errors_on(changeset)
    end
  end

  describe "tasks and attempts" do
    test "task keys are unique per run and revision", ctx do
      {:ok, run} = Runs.start_run(workspace!(ctx), %{goal: "g"})
      assert {:ok, %Task{status: :queued, revision: 1}} = Runs.create_task(run, task_attrs())
      assert {:error, changeset} = Runs.create_task(run, task_attrs())
      assert %{run_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, %Task{revision: 2}} =
               Runs.create_task(run, Map.put(task_attrs(), :revision, 2))
    end

    test "task fields are validated", ctx do
      {:ok, run} = Runs.start_run(workspace!(ctx), %{goal: "g"})
      assert {:error, changeset} = Runs.create_task(run, %{key: "Bad Key"})

      assert %{key: [_], title: [_], goal: [_], mutates: [_]} = errors_on(changeset)
    end

    test "attempts are numbered per task and start queued", ctx do
      attempt = attempt!(ctx)
      assert %Attempt{number: 1, status: :queued, role: :writer} = attempt

      task = Runs.get_task!(attempt.task_id)
      assert {:ok, %Attempt{number: 2}} = Runs.create_attempt(task, %{role: :reader})
      assert {:error, changeset} = Runs.create_attempt(task, %{})
      assert %{role: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "attempt state machine" do
    test "every pair of statuses is allowed exactly as the table says" do
      transitions = Attempt.transitions()

      for from <- Attempt.statuses(), to <- Attempt.statuses() do
        expected = to in transitions[from]
        assert Attempt.allowed?(from, to) == expected, "#{from} -> #{to}"

        changeset = Attempt.transition_changeset(%Attempt{status: from}, to)
        assert changeset.valid? == expected, "changeset #{from} -> #{to}"
      end
    end

    test "the happy path runs from queued to accepted" do
      path = [:queued, :admitted, :running, :result_received, :settling, :verifying, :accepted]

      for [from, to] <- Enum.chunk_every(path, 2, 1, :discard),
          do: assert(Attempt.allowed?(from, to), "#{from} -> #{to}")
    end

    test "every in-flight status can fail, be cancelled or need reconciliation" do
      for from <- Attempt.in_flight_statuses(),
          to <- [:failed, :cancelled, :needs_reconciliation],
          do: assert(Attempt.allowed?(from, to), "#{from} -> #{to}")
    end

    test "a transition is persisted with its fields", ctx do
      attempt = attempt!(ctx)

      assert {:ok, %Attempt{status: :admitted, tree_before: "abc"} = admitted} =
               Runs.transition_attempt(attempt, :admitted, %{tree_before: "abc"})

      writes = [%{"path" => "a.txt", "status" => "added"}]

      assert {:ok, %Attempt{status: :running, agent_id: "w1", session_epoch: 1}} =
               Runs.transition_attempt(admitted, :running, %{agent_id: "w1", session_epoch: 1})

      running = Runs.get_attempt!(attempt.id)

      assert {:ok, %Attempt{actual_writes: ^writes}} =
               Runs.transition_attempt(running, :settling, %{actual_writes: writes})
    end

    test "an illegal transition changes nothing", ctx do
      attempt = attempt!(ctx)

      assert {:error, {:illegal, :queued, :accepted}} =
               Runs.transition_attempt(attempt, :accepted)

      assert Runs.get_attempt!(attempt.id).status == :queued
    end

    test "a transition from a status that is no longer stored is stale", ctx do
      attempt = attempt!(ctx)
      {:ok, _} = Runs.transition_attempt(attempt, :admitted)

      # `attempt` still says :queued; the database says :admitted.
      assert {:error, :stale} = Runs.transition_attempt(attempt, :cancelled)
      assert Runs.get_attempt!(attempt.id).status == :admitted
    end

    test "in-flight attempts are listed for recovery", ctx do
      attempt = attempt!(ctx)
      assert Runs.list_in_flight_attempts() == []

      {:ok, admitted} = Runs.transition_attempt(attempt, :admitted)
      assert [%Attempt{id: id}] = Runs.list_in_flight_attempts()
      assert id == admitted.id
    end
  end
end
