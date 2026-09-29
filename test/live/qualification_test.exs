defmodule Bm.Live.QualificationTest do
  @moduledoc """
  Stage A6 qualification against the real pi, Fabric and model. Each test answers one open
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

  defp prompt_code(ctx, code) do
    :ok =
      Bm.Pi.prompt(
        ctx.id,
        "Call the fabric_exec tool exactly once with exactly this code, then reply \"done\":\n" <>
          code
      )
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

  test "reader: a bm: dialog from inside fabric_exec reaches the BEAM and returns its answer",
       ctx do
    report = start!(ctx, :reader)
    IO.puts("\n[qualification] reader active tools: #{inspect(Enum.sort(report.tools))}")

    prompt_code(
      ctx,
      ~s|const r = await extensions.submit_result({ status: "done", summary: "nested" });\nreturn r;|
    )

    requests = serve(ctx, fn _ -> %{"ok" => true, "status" => "received"} end)
    assert [%{op: "submit_result", payload: %{"summary" => "nested"}}] = requests
  end

  test "reader: pi.write inside fabric_exec cannot create files (--tools restricts nested calls)",
       ctx do
    start!(ctx, :reader)

    prompt_code(
      ctx,
      ~s|try { await pi.write({ path: "q3.txt", content: "x" }); return "wrote"; } catch (e) { return "error: " + String(e); }|
    )

    serve(ctx, fn _ -> %{"ok" => true} end)
    refute File.exists?(Path.join(ctx.dir, "q3.txt"))
  end

  test "writer: bm_guard fires for nested pi.write, awaits the BEAM, and a denial writes nothing",
       ctx do
    start!(ctx, :writer)

    prompt_code(ctx, """
    try { await pi.write({ path: "denied.txt", content: "x" }); } catch (e) {}
    await pi.write({ path: "allowed.txt", content: "y" });
    return "ok";
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

  test "writer: background bash is visible to the guard, and descendants outlive agent_settled",
       ctx do
    start!(ctx, :writer)
    prompt_code(ctx, ~s|return await pi.bash({ command: "sleep 45", background: true });|)

    requests = serve(ctx, fn _ -> %{"ok" => true, "allow" => true} end)
    bash = Enum.find(requests, &match?(%{op: "authorize", payload: %{"tool" => "bash"}}, &1))
    IO.puts("\n[qualification] guard saw bash input: #{inspect(bash && bash.payload["input"])}")
    assert bash

    descendants = descendants(Bm.Pi.os_pid(ctx.id))
    IO.puts("[qualification] descendants after agent_settled: #{inspect(descendants)}")
    assert Enum.any?(descendants, &(&1 =~ "sleep 45"))
    for line <- descendants, [pid | _] = String.split(line), do: System.cmd("kill", [pid])
  end

  defp descendants(pid) do
    {out, _} = System.cmd("ps", ["-axo", "pid=,ppid=,command="])

    rows =
      for line <- String.split(out, "\n", trim: true) do
        [p, pp | cmd] = String.split(String.trim(line), ~r/\s+/, parts: 3)
        {String.to_integer(p), String.to_integer(pp), Enum.join(cmd, " ")}
      end

    collect(rows, [pid])
  end

  defp collect(_rows, []), do: []

  defp collect(rows, parents) do
    children = for {p, pp, cmd} <- rows, pp in parents, do: {p, cmd}

    Enum.map(children, fn {p, cmd} -> "#{p} #{cmd}" end) ++
      collect(rows, Enum.map(children, &elem(&1, 0)))
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
