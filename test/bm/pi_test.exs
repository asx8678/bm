defmodule Bm.PiTest do
  use ExUnit.Case, async: true

  setup context do
    id = "test-#{System.unique_integer([:positive])}"
    Bm.Pi.subscribe(id)
    opts = if context[:owner], do: [owner: self()], else: []
    {:ok, _pid} = Bm.Pi.ensure_agent(id, opts)
    on_exit(fn -> Bm.Pi.stop(id) end)

    assert_receive {:pi, ^id, :status, %{status: :idle, model: "Fake Model"}}, 5_000
    %{id: id}
  end

  defp settle(id) do
    assert_receive {:pi, ^id, :status, %{status: :idle}}, 5_000
    Bm.Pi.snapshot(id)
  end

  describe "commands" do
    test "a prompt returns :ok once pi accepted it and streams back a reply", %{id: id} do
      assert :ok = Bm.Pi.prompt(id, "hello")
      %{transcript: transcript} = settle(id)

      assert [%{role: :user, text: "hello"}, %{role: :assistant, text: "echo: hello"}] =
               transcript
    end

    test "new_session replies only after pi confirms and then clears the transcript", %{id: id} do
      Bm.Pi.prompt(id, "hello")
      settle(id)
      %{summary: %{session_epoch: epoch}} = Bm.Pi.snapshot(id)

      assert :ok = Bm.Pi.new_session(id)
      assert %{transcript: [], summary: %{session_epoch: new_epoch}} = Bm.Pi.snapshot(id)
      assert new_epoch == epoch + 1
    end

    test "a refused new_session is reported to the caller and keeps the session", %{id: id} do
      Bm.Pi.prompt(id, "break-reset")
      settle(id)
      %{summary: %{session_epoch: epoch}} = Bm.Pi.snapshot(id)

      assert {:error, "reset refused"} = Bm.Pi.new_session(id)
      assert %{transcript: [_ | _], summary: %{session_epoch: ^epoch}} = Bm.Pi.snapshot(id)
    end

    test "follow_up is accepted and delivered", %{id: id} do
      assert :ok = Bm.Pi.follow_up(id, "later")
      %{transcript: transcript} = settle(id)
      assert %{role: :assistant, text: "followed: later"} = List.last(transcript)
    end

    test "the agent survives pi exiting and restarts it with a new session epoch", %{id: id} do
      %{summary: %{session_epoch: epoch}} = Bm.Pi.snapshot(id)
      Bm.Pi.prompt(id, "crash")

      assert_receive {:pi, ^id, {:error, "pi exited with status 3" <> _}, %{status: :exited}},
                     5_000

      Bm.Pi.prompt(id, "again")
      assert_receive {:pi, ^id, :status, %{status: :idle}}, 5_000
      assert %{transcript: transcript, summary: %{session_epoch: new_epoch}} = settle(id)
      assert %{role: :assistant, text: "echo: again"} = List.last(transcript)
      assert new_epoch > epoch
    end
  end

  describe "process groups" do
    defp spawn_children(id) do
      Bm.Pi.prompt(id, "spawn-child")
      %{summary: %{pgid: pgid, pgid_file: file}} = settle(id)
      assert pgid == Bm.Pi.os_pid(id)
      assert [bash_group] = Bm.Proc.read_pgid_file(file)

      groups = [pgid, bash_group]
      # pi and its plain child, and the bash command's background job.
      assert length(Bm.Proc.group_members(groups)) == 3
      {groups, file}
    end

    test "stopping the agent ends pi's group and every recorded bash group", %{id: id} do
      {groups, file} = spawn_children(id)

      Bm.Pi.stop(id)
      assert Bm.Proc.group_members(groups) == []
      refute File.exists?(file)
    end

    test "live groups are reported, and a group seen empty is never reported again", %{id: id} do
      {[pgid, bash_group] = groups, _file} = spawn_children(id)
      assert Bm.Pi.process_groups(id) == groups

      Bm.Proc.terminate_groups([bash_group])
      assert Bm.Pi.process_groups(id) == [pgid]
    end

    test "processes left behind are ended when pi exits by itself", %{id: id} do
      {groups, _file} = spawn_children(id)

      Bm.Pi.prompt(id, "crash")
      assert_receive {:pi, ^id, {:error, "pi exited" <> _}, %{pgid: nil}}, 5_000
      assert Bm.Proc.group_members(groups) == []
    end
  end

  describe "usage and spend" do
    test "usage keeps the cost and spend adds confirmed cost per message", %{id: id} do
      Bm.Pi.prompt(id, "hello")
      %{summary: summary} = settle(id)

      assert summary.usage == %{input: 10, output: 2, cache_read: 5, cost: nil}
      assert summary.spend == %{confirmed: 0.003, unknown: 0}
    end

    test "a message without cost counts as unknown, not zero", %{id: id} do
      Bm.Pi.prompt(id, "nocost")
      %{summary: summary} = settle(id)
      assert summary.spend == %{confirmed: 0.0, unknown: 1}
    end
  end

  describe "events" do
    test "tool calls appear in the transcript and the summary", %{id: id} do
      Bm.Pi.prompt(id, "tool please")

      assert_receive {:pi, ^id, {:tool_start, "call-1", "read", "mix.exs"},
                      %{tool: "read mix.exs"}},
                     5_000

      %{transcript: transcript, summary: summary} = settle(id)
      assert Enum.any?(transcript, &match?(%{role: :tool, name: "read", status: :ok}, &1))
      assert summary.tool == nil
    end

    test "model errors are reported", %{id: id} do
      Bm.Pi.prompt(id, "fail")
      assert %{transcript: transcript} = settle(id)
      assert List.last(transcript) == %{role: :error, text: "boom"}
    end

    test "non-BM dialogs are declined so pi does not block", %{id: id} do
      Bm.Pi.prompt(id, "dialog")
      assert %{transcript: transcript} = settle(id)

      assert Enum.any?(
               transcript,
               &match?(%{role: :notice, text: "Declined pi dialog: Allow?"}, &1)
             )

      assert %{role: :assistant, text: "dialog: cancelled"} = List.last(transcript)
    end

    test "streamed tool calls are proposals: early when complete, final at the end", %{id: id} do
      Bm.Pi.prompt(id, "plan")

      for key <- ["a", "b", "c"] do
        assert_receive {:pi, ^id,
                        {:tool_call, :early, %{name: "add_task", arguments: %{"id" => ^key}}}, _},
                       5_000
      end

      for key <- ["a", "b", "c"] do
        assert_receive {:pi, ^id,
                        {:tool_call, :final, %{name: "add_task", arguments: %{"id" => ^key}}}, _},
                       5_000
      end

      settle(id)
      refute_received {:pi, ^id, {:tool_call, _, _}, _}
    end

    test "bridge telemetry arrives as events", %{id: id} do
      Bm.Pi.prompt(id, "report")

      assert_receive {:pi, ^id, {:bridge, "result", %{"status" => "done", "summary" => "probe"}},
                      _},
                     5_000
    end
  end

  describe "scripted work (fake pi)" do
    @describetag owner: true
    @describetag :tmp_dir

    defp work(id, steps), do: Bm.Pi.prompt(id, "work:" <> JSON.encode!(steps))

    defp answer_next(id, op, reply) do
      assert_receive {:pi_request, ^id, %{op: ^op, dialog_id: dialog_id} = request}, 5_000
      Bm.Pi.respond(id, dialog_id, reply)
      request
    end

    test "steps ask the BEAM, write, run recorded commands and submit", %{id: id, tmp_dir: dir} do
      file = Path.join(dir, "out.txt")

      work(id, [
        %{authorize: %{tool: "write", input: %{path: file}}},
        %{write: [file, "hi"]},
        %{bash: "true"},
        %{submit: %{status: "done", summary: "did it"}}
      ])

      allow = %{"ok" => true, "allow" => true}
      assert %{payload: %{"tool" => "write"}} = answer_next(id, "authorize", allow)
      assert %{payload: %{"tool" => "bash"}} = answer_next(id, "authorize", allow)

      assert %{payload: %{"status" => "done"}} =
               answer_next(id, "submit_result", %{"ok" => true})

      %{transcript: transcript, summary: %{pgid_file: pgid_file}} = settle(id)
      assert %{role: :assistant, text: "worked"} = List.last(transcript)
      assert File.read!(file) == "hi"
      assert [_bash_group] = Bm.Proc.read_pgid_file(pgid_file)
    end

    test "a denied authorization stops the work", %{id: id, tmp_dir: dir} do
      file = Path.join(dir, "out.txt")
      work(id, [%{bash: "touch #{file}"}, %{write: [file, "no"]}])
      answer_next(id, "authorize", %{"ok" => true, "allow" => false, "reason" => "policy"})

      %{transcript: transcript} = settle(id)
      assert %{text: "denied: policy"} = List.last(transcript)
      refute File.exists?(file)
    end

    test "a spawned background job is recorded; hang waits until aborted", %{id: id} do
      work(id, [%{spawn: "sleep 60"}, %{hang: true}])
      assert_receive {:pi, ^id, :status, %{status: :running}}, 5_000

      # Wait until the background job is recorded.
      pgid_file = Bm.Pi.snapshot(id).summary.pgid_file
      assert eventually(fn -> Bm.Proc.read_pgid_file(pgid_file) != [] end)

      assert :ok = Bm.Pi.abort(id)
      %{transcript: transcript} = settle(id)
      assert %{role: :notice, text: "Stopped."} = List.last(transcript)
      assert [_pi, _job] = Bm.Pi.process_groups(id)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> receive(after: (20 -> eventually(fun, attempts - 1)))
    end
  end

  describe "authoritative bridge requests" do
    @describetag owner: true

    test "a bm: dialog is forwarded to the owner and the tool gets the owner's reply", %{id: id} do
      Bm.Pi.prompt(id, "bm-dialog")

      assert_receive {:pi_request, ^id,
                      %{
                        op: "submit_result",
                        request_id: "req-1",
                        payload: %{"status" => "done"},
                        dialog_id: dialog_id,
                        session_epoch: epoch
                      }},
                     5_000

      assert is_integer(epoch)
      Bm.Pi.respond(id, dialog_id, %{"ok" => true, "status" => "received"})

      %{transcript: transcript} = settle(id)
      assert %{text: ~s(bm reply: {"ok":true,"status":"received"})} = List.last(transcript)
    end

    test "a malformed request is rejected without reaching the owner", %{id: id} do
      Bm.Pi.prompt(id, "bm-bad")
      %{transcript: transcript} = settle(id)

      assert %{text: ~s(bm reply: {"error":"malformed_request","ok":false})} =
               List.last(transcript)

      refute_received {:pi_request, _, _}
    end

    test "answers to unknown dialogs are ignored", %{id: id} do
      Bm.Pi.respond(id, "no-such-dialog", %{"ok" => true})
      assert :ok = Bm.Pi.prompt(id, "hello")
      assert %{transcript: [_, %{text: "echo: hello"}]} = settle(id)
    end
  end

  test "without an owner, bm: requests fail closed", %{id: id} do
    Bm.Pi.prompt(id, "bm-dialog")
    %{transcript: transcript} = settle(id)
    assert %{text: ~s(bm reply: {"error":"no_owner","ok":false})} = List.last(transcript)
  end
end

defmodule Bm.PiOptionsTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "extra environment reaches pi and raw output is logged", %{tmp_dir: dir} do
    id = "opts-#{System.unique_integer([:positive])}"
    log = Path.join(dir, "raw.jsonl")
    Bm.Pi.subscribe(id)
    {:ok, _} = Bm.Pi.ensure_agent(id, env: %{"PI_FABRIC_DEPTH" => "99"}, raw_log: log)
    on_exit(fn -> Bm.Pi.stop(id) end)

    assert_receive {:pi, ^id, :status, %{status: :idle}}, 5_000
    assert File.read!(log) =~ ~s("sessionName":"depth-99")
    assert is_integer(Bm.Pi.os_pid(id))
  end
end
