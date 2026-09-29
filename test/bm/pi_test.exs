defmodule Bm.PiTest do
  use ExUnit.Case, async: true

  setup do
    id = "test-#{System.unique_integer([:positive])}"
    Bm.Pi.subscribe(id)
    {:ok, _pid} = Bm.Pi.ensure_agent(id)
    on_exit(fn -> Bm.Pi.stop(id) end)

    assert_receive {:pi, ^id, :status, %{status: :idle, model: "Fake Model"}}, 5_000
    %{id: id}
  end

  defp settle(id) do
    assert_receive {:pi, ^id, :status, %{status: :idle}}, 5_000
    Bm.Pi.snapshot(id)
  end

  test "a prompt streams back an assistant reply", %{id: id} do
    assert :ok = Bm.Pi.prompt(id, "hello")
    assert_receive {:pi, ^id, :status, %{status: :running}}, 5_000

    %{transcript: transcript, summary: summary} = settle(id)

    assert [%{role: :user, text: "hello"}, %{role: :assistant, text: "echo: hello"}] = transcript
    assert summary.usage == %{input: 10, output: 2, cache_read: 5}
  end

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

  test "dialogs are declined so pi does not block", %{id: id} do
    Bm.Pi.prompt(id, "dialog")
    assert %{transcript: transcript} = settle(id)

    assert Enum.any?(
             transcript,
             &match?(%{role: :notice, text: "Declined pi dialog: Allow?"}, &1)
           )

    assert %{role: :assistant, text: "dialog: cancelled"} = List.last(transcript)
  end

  test "the agent survives pi exiting and restarts it on the next prompt", %{id: id} do
    Bm.Pi.prompt(id, "crash")
    assert_receive {:pi, ^id, {:error, "pi exited with status 3" <> _}, %{status: :exited}}, 5_000

    Bm.Pi.prompt(id, "again")
    assert_receive {:pi, ^id, :status, %{status: :idle}}, 5_000
    assert %{transcript: transcript} = settle(id)
    assert %{role: :assistant, text: "echo: again"} = List.last(transcript)
  end

  test "streamed tool calls are reported one by one, before the message ends", %{id: id} do
    Bm.Pi.prompt(id, "plan")

    for task <- ["a", "b", "c"] do
      assert_receive {:pi, ^id,
                      {:tool_call_ready, %{name: "add_task", arguments: %{"id" => ^task}}}, _},
                     5_000
    end

    settle(id)
    refute_received {:pi, ^id, {:tool_call_ready, _}, _}
  end

  test "bridge reports arrive as events", %{id: id} do
    Bm.Pi.prompt(id, "report")

    assert_receive {:pi, ^id, {:bridge, "result", %{"status" => "done", "summary" => "probe"}},
                    _},
                   5_000
  end

  test "new_session clears the transcript and keeps the process", %{id: id} do
    Bm.Pi.prompt(id, "hello")
    settle(id)

    assert :ok = Bm.Pi.new_session(id)
    assert %{transcript: [], summary: %{status: :idle}} = Bm.Pi.snapshot(id)

    Bm.Pi.prompt(id, "again")
    assert %{transcript: [_, %{role: :assistant, text: "echo: again"}]} = settle(id)
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
  end
end
