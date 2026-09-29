defmodule Bm.BridgeTest do
  use Bm.DataCase, async: true

  alias Bm.Bridge

  defp request(op, request_id \\ Ecto.UUID.generate()) do
    %{op: op, request_id: request_id, payload: %{"status" => "done"}, session_epoch: 1}
  end

  defp accept(_request), do: %{"ok" => true, "status" => "received"}

  test "an allowed request runs once and is persisted with its outcome" do
    req = request("submit_result")
    assert %{"ok" => true} = Bridge.handle(:worker, "w1", req, &accept/1)

    assert [%{agent_id: "w1", role: "worker", op: "submit_result", outcome: %{"ok" => true}}] =
             Repo.all(Bridge.Request)
  end

  test "a duplicate request returns the stored outcome without running again" do
    req = request("submit_result")
    parent = self()

    counting = fn _ ->
      send(parent, :ran)
      %{"ok" => true, "n" => 1}
    end

    assert %{"n" => 1} = Bridge.handle(:worker, "w1", req, counting)
    assert %{"n" => 1} = Bridge.handle(:worker, "w1", req, counting)
    assert_received :ran
    refute_received :ran
  end

  test "roles are limited to their own operations" do
    assert %{"ok" => false, "error" => "operation_not_allowed"} =
             Bridge.handle(:worker, "w1", request("propose_task"), &accept/1)

    assert %{"ok" => false, "error" => "operation_not_allowed"} =
             Bridge.handle(:planner, "p1", request("submit_result"), &accept/1)

    assert Repo.all(Bridge.Request) == []
  end

  test "the same request id from a different agent is rejected" do
    req = request("submit_result")
    Bridge.handle(:worker, "w1", req, &accept/1)

    assert %{"ok" => false, "error" => "request_id_conflict"} =
             Bridge.handle(:worker, "w2", req, &accept/1)
  end

  test "if the handler raises, nothing is persisted" do
    req = request("submit_result")
    boom = fn _ -> raise "boom" end
    assert_raise RuntimeError, fn -> Bridge.handle(:worker, "w1", req, boom) end
    assert Repo.all(Bridge.Request) == []
  end
end
