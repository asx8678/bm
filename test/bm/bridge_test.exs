defmodule Bm.BridgeTest do
  use Bm.DataCase, async: true

  alias Bm.Bridge

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, workspace} = Bm.Runs.ensure_workspace(dir)
    {:ok, run} = Bm.Runs.start_run(workspace, %{goal: "g"})

    {:ok, task} =
      Bm.Runs.create_task(run, %{key: "t", title: "T", goal: "Do it.", mutates: false})

    {:ok, attempt} = Bm.Runs.create_attempt(task, %{role: :reader})
    %{worker: %{session_epoch: 1, attempt_id: attempt.id}, planner: %{session_epoch: 1}}
  end

  defp request(op, request_id \\ Ecto.UUID.generate(), epoch \\ 1) do
    %{op: op, request_id: request_id, payload: %{"status" => "done"}, session_epoch: epoch}
  end

  defp accept(_request), do: %{"ok" => true, "status" => "received"}

  test "an allowed request runs once and is persisted with its outcome and attempt", ctx do
    req = request("submit_result")
    assert %{"ok" => true} = Bridge.handle(:worker, "w1", req, ctx.worker, &accept/1)

    attempt_id = ctx.worker.attempt_id

    assert [
             %{
               agent_id: "w1",
               role: "worker",
               op: "submit_result",
               attempt_id: ^attempt_id,
               outcome: %{"ok" => true}
             }
           ] = Repo.all(Bridge.Request)
  end

  test "a planner request needs no attempt", ctx do
    assert %{"ok" => true} =
             Bridge.handle(:planner, "p1", request("close_plan"), ctx.planner, &accept/1)

    assert [%{attempt_id: nil}] = Repo.all(Bridge.Request)
  end

  test "a duplicate request returns the stored outcome without running again", ctx do
    req = request("submit_result")
    parent = self()

    counting = fn _ ->
      send(parent, :ran)
      %{"ok" => true, "n" => 1}
    end

    assert %{"n" => 1} = Bridge.handle(:worker, "w1", req, ctx.worker, counting)
    assert %{"n" => 1} = Bridge.handle(:worker, "w1", req, ctx.worker, counting)
    assert_received :ran
    refute_received :ran
  end

  test "roles are limited to their own operations", ctx do
    assert %{"ok" => false, "error" => "operation_not_allowed"} =
             Bridge.handle(:worker, "w1", request("propose_task"), ctx.worker, &accept/1)

    assert %{"ok" => false, "error" => "operation_not_allowed"} =
             Bridge.handle(:planner, "p1", request("submit_result"), ctx.planner, &accept/1)

    assert Repo.all(Bridge.Request) == []
  end

  describe "fencing" do
    defp refuse(_request), do: flunk("the handler must not run")

    test "a request from an earlier pi session is stale and runs nothing", ctx do
      old = request("submit_result", Ecto.UUID.generate(), 0)

      assert %{"ok" => false, "error" => "stale"} =
               Bridge.handle(:worker, "w1", old, ctx.worker, &refuse/1)

      assert Repo.all(Bridge.Request) == []
    end

    test "a request while nothing is assigned is rejected" do
      assert %{"ok" => false, "error" => "not_assigned"} =
               Bridge.handle(:worker, "w1", request("submit_result"), nil, &refuse/1)

      assert %{"ok" => false, "error" => "not_assigned"} =
               Bridge.handle(:planner, "p1", request("close_plan"), nil, &refuse/1)

      assert Repo.all(Bridge.Request) == []
    end

    test "a worker without an attempt is not assigned", ctx do
      assert %{"ok" => false, "error" => "not_assigned"} =
               Bridge.handle(:worker, "w1", request("submit_result"), ctx.planner, &refuse/1)
    end

    test "a stale duplicate doesn't return the stored outcome", ctx do
      id = Ecto.UUID.generate()
      Bridge.handle(:worker, "w1", request("submit_result", id), ctx.worker, &accept/1)
      next_session = %{ctx.worker | session_epoch: 2}

      assert %{"ok" => false, "error" => "stale"} =
               Bridge.handle(:worker, "w1", request("submit_result", id), next_session, &refuse/1)
    end
  end

  test "the same request id from a different agent is rejected", ctx do
    req = request("submit_result")
    Bridge.handle(:worker, "w1", req, ctx.worker, &accept/1)

    assert %{"ok" => false, "error" => "request_id_conflict"} =
             Bridge.handle(:worker, "w2", req, ctx.worker, &accept/1)
  end

  test "if the handler raises, nothing is persisted", ctx do
    req = request("submit_result")
    boom = fn _ -> raise "boom" end
    assert_raise RuntimeError, fn -> Bridge.handle(:worker, "w1", req, ctx.worker, boom) end
    assert Repo.all(Bridge.Request) == []
  end
end
