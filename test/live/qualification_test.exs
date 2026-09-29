defmodule Bm.Live.QualificationTest do
  @moduledoc """
  Stage A6 qualification against the real pi and model (workers are Fabric-free, decision D16). Each test answers one open
  question from docs/ARCHITECTURE.md §14 and costs one short model call.

      mix test --only live                       # run
      RECORD_FIXTURES=1 mix test --only live     # also save sanitized replay fixtures

  Uses the real profiles from config/config.exs, so pi, zro and Fabric must be installed.
  """

  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 300_000

  alias Bm.Pi.Profile

  @real_profile [
    pi_command: ["pi"],
    model: "zro/glm-5.3",
    zro_extension: Path.expand("~/.pi/agent/npm/node_modules/pi-zro-provider"),
    fabric_extension: Path.expand("~/.pi/agent/npm/node_modules/pi-fabric"),
    pi_version: "0.87.1",
    fabric_version: "0.97.0"
  ]

  setup context do
    previous = Application.get_env(:bm, Profile)
    Application.put_env(:bm, Profile, @real_profile)

    dir = Path.join(System.tmp_dir!(), "bm-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    id = "live-#{context.test |> to_string() |> String.replace(~r/\W+/, "-")}"
    log = Path.join(dir, "raw.jsonl")

    on_exit(fn ->
      Bm.Pi.stop(id)
      Application.put_env(:bm, Profile, previous)
      if System.get_env("RECORD_FIXTURES"), do: save_fixture(context.test, log, dir)
      File.rm_rf!(dir)
    end)

    %{id: id, dir: dir, log: log}
  end

  defp start!(ctx, role) do
    assert {:ok, report} =
             Profile.start(ctx.id, role, owner: self(), cwd: ctx.dir, raw_log: ctx.log)

    Bm.Pi.subscribe(ctx.id)
    flush(ctx.id)
    report
  end

  # Drops status events left over from start-up so `serve/2` only sees the prompt's events.
  defp flush(id) do
    receive do
      {:pi, ^id, _, _} -> flush(id)
    after
      0 -> :ok
    end
  end

  # Serves bm: requests with `answer` until the agent settles; returns requests seen in order.
  defp serve(ctx, answer, timeout \\ 240_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_serve(ctx.id, answer, [], deadline)
  end

  defp do_serve(id, answer, seen, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:pi_request, ^id, request} ->
        Bm.Pi.respond(id, request.dialog_id, answer.(request))
        do_serve(id, answer, [request | seen], deadline)

      {:pi, ^id, :status, %{status: :idle}} ->
        Enum.reverse(seen)

      {:pi, ^id, _, _} ->
        do_serve(id, answer, seen, deadline)
    after
      remaining -> flunk("agent did not settle; requests so far: #{inspect(Enum.reverse(seen))}")
    end
  end

  test "planner: the profile check passes and propose_task / close_plan are answered by the BEAM",
       ctx do
    report = start!(ctx, :planner)
    assert Enum.sort(report.tools) == Enum.sort(~w(read grep find ls propose_task close_plan))

    :ok =
      Bm.Pi.prompt(ctx.id, """
      Call propose_task exactly once with key "probe", title "Probe", goal "Nothing to do.",
      mutates false, done_when "Never.", then call close_plan with summary "probe". Do nothing else.
      """)

    requests = serve(ctx, fn _ -> %{"ok" => true, "status" => "accepted"} end)
    assert Enum.map(requests, & &1.op) == ~w(propose_task close_plan)
    assert hd(requests).payload["key"] == "probe"
  end

  test "reader: submit_result is answered by the BEAM; mutating tools are not available", ctx do
    report = start!(ctx, :reader)
    assert Enum.sort(report.tools) == Enum.sort(~w(read grep find ls submit_result))

    :ok =
      Bm.Pi.prompt(ctx.id, """
      First try to create the file q3.txt containing "x" with any tool you have. Then call
      submit_result with status "done" and summary "reader probe". Do nothing else.
      """)

    requests = serve(ctx, fn _ -> %{"ok" => true, "status" => "received"} end)
    # The model may report "done" or honestly "blocked"; what matters is the request and no file.
    assert [%{op: "submit_result", payload: %{"status" => _}}] = requests
    refute File.exists?(Path.join(ctx.dir, "q3.txt"))
  end

  test "writer: bm_guard awaits the BEAM for every write and a denial writes nothing", ctx do
    report = start!(ctx, :writer)

    assert Enum.sort(report.tools) ==
             Enum.sort(~w(read grep find ls edit write bash submit_result))

    :ok =
      Bm.Pi.prompt(ctx.id, """
      Use the write tool twice: create denied.txt containing "x", then create allowed.txt
      containing "y". If a write is blocked, continue with the next one. Do nothing else.
      """)

    requests =
      serve(ctx, fn
        %{op: "authorize", payload: %{"input" => %{"path" => path}}} ->
          if path =~ "denied",
            do: %{"ok" => true, "allow" => false, "reason" => "test denial"},
            else: %{"ok" => true, "allow" => true}

        _ ->
          %{"ok" => true, "allow" => true}
      end)

    paths = for %{op: "authorize", payload: %{"input" => %{"path" => p}}} <- requests, do: p
    assert Enum.any?(paths, &(&1 =~ "denied")) and Enum.any?(paths, &(&1 =~ "allowed"))
    refute File.exists?(Path.join(ctx.dir, "denied.txt"))
    assert File.read!(Path.join(ctx.dir, "allowed.txt")) == "y"
  end

  # D18: pi runs every bash command in a session of its own, outside pi's process group.
  # bm_guard records each allowed command's group id in BM_PGID_FILE, so a backgrounded job is
  # still found after the agent settles, and stopping the agent ends it.
  test "writer: bm_guard records each bash command's process group", ctx do
    start!(ctx, :writer)
    %{summary: %{pgid: pgid, pgid_file: file}} = Bm.Pi.snapshot(ctx.id)

    :ok =
      Bm.Pi.prompt(ctx.id, """
      Run exactly this bash command once: nohup sleep 45 >/dev/null 2>&1 & echo started-ok
      Then reply with the command's output and nothing else.
      """)

    requests = serve(ctx, fn _ -> %{"ok" => true, "allow" => true} end)

    # The BEAM authorizes the model's original command, not the prefixed one.
    assert %{payload: %{"input" => %{"command" => command}}} =
             Enum.find(requests, &match?(%{op: "authorize", payload: %{"tool" => "bash"}}, &1))

    refute command =~ "printf"

    # The model saw the command's normal output.
    %{transcript: transcript} = Bm.Pi.snapshot(ctx.id)
    assert %{role: :assistant, text: text} = List.last(transcript)
    assert text =~ "started-ok"

    groups = Bm.Proc.read_pgid_file(file)
    assert [_ | _] = groups
    refute pgid in groups
    assert [_ | _] = Bm.Proc.group_members(groups), "the background sleep should still run"

    Bm.Pi.stop(ctx.id)
    assert Bm.Proc.group_members([pgid | groups]) == []
  end

  # Sanitized copy of the raw RPC stream for replay tests: local paths are replaced.
  defp save_fixture(test, log, dir) do
    with {:ok, raw} <- File.read(log) do
      name = test |> to_string() |> String.replace(~r/\W+/, "_") |> String.slice(0, 60)

      sanitized =
        raw
        |> String.replace(dir, "<CWD>")
        |> String.replace(File.cwd!(), "<BM>")
        |> String.replace(System.user_home!(), "<HOME>")

      File.write!(Path.join([File.cwd!(), "test/fixtures/pi", "#{name}.jsonl"]), sanitized)
    end
  end
end
