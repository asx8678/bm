defmodule Bm.Live.MilestoneBTest do
  @moduledoc """
  Milestone B exit gate (docs/FEATURES.md) against the real pi and model: one guarded worker in a
  scratch repository that holds the user's uncommitted work (a staged change and a dirty file).

      mix test --only live test/live/milestone_b_test.exs

  Costs a few short model sessions. Each step prints what happened.
  """

  use Bm.DataCase, async: false

  alias Bm.Runs
  alias Bm.Workspace.{Coordinator, Recovery}

  @moduletag :live
  @moduletag timeout: 1_200_000

  @real_profile [
    pi_command: ["pi"],
    model: "zro/glm-5.3",
    zro_extension: Path.expand("~/.pi/agent/npm/node_modules/pi-zro-provider"),
    fabric_extension: Path.expand("~/.pi/agent/npm/node_modules/pi-fabric"),
    pi_version: "0.87.1",
    fabric_version: "0.97.0"
  ]

  # Fails when any .txt file contains BROKEN: the "verification" of this scratch project.
  @check """
  #!/bin/sh
  if grep -l BROKEN *.txt 2>/dev/null; then echo "found BROKEN"; exit 1; fi
  echo "check ok"
  """

  setup do
    previous = Application.get_env(:bm, Bm.Pi.Profile)
    Application.put_env(:bm, Bm.Pi.Profile, @real_profile)

    # Outside this project: a workspace must be the top level of its own repository.
    repo = Path.join(System.tmp_dir!(), "bm-milestone-b-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "Scratch project for BM's milestone B gate.\n")
    File.write!(Path.join(repo, "check.sh"), @check)
    File.write!(Path.join(repo, "staged.txt"), "v1\n")
    File.write!(Path.join(repo, "notes.txt"), "v1\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "initial"])
    # The user's uncommitted work.
    File.write!(Path.join(repo, "staged.txt"), "user's staged change\n")
    git!(repo, ["add", "staged.txt"])
    File.write!(Path.join(repo, "notes.txt"), "user's unsaved notes\n")

    {:ok, _pid} = Coordinator.ensure_started(repo)
    :ok = Coordinator.subscribe(repo)

    on_exit(fn ->
      Coordinator.stop(repo)
      Application.put_env(:bm, Bm.Pi.Profile, previous)
      File.rm_rf!(repo)
    end)

    %{repo: repo, cached: git!(repo, ["diff", "--cached"])}
  end

  test "milestone B: accepted, refused, held and reverted, and recovered", %{repo: repo} = ctx do
    ## 1. A plain task is verified and checkpointed; the user's work is untouched.
    attempt =
      run!(repo, "Create a file hello.txt containing exactly the text: hi", writes: ["hello.txt"])

    report("1 hello.txt", attempt)
    assert attempt.status == :accepted
    assert String.trim(File.read!(Path.join(repo, "hello.txt"))) == "hi"
    assert git!(repo, ["cat-file", "-p", "#{attempt.checkpoint_ref}:hello.txt"]) == "hi"
    assert_user_work_untouched(ctx)

    ## 2. A task that needs the user's dirty file fails; the file ends up as the user left it.
    attempt = run!(repo, "Append a line with the text 'more' to the file notes.txt.")
    report("2 notes.txt", attempt)
    assert attempt.status == :failed

    # The policy refuses edit/write and shell writes (redirects, tee, sed -i, cp/mv) to the file.
    # A write it cannot see would be caught by the snapshot and wait for a revert.
    if match?(%{lane: {:held, _}}, Coordinator.state(repo)),
      do: assert(:ok = Coordinator.revert(repo))

    assert_user_work_untouched(ctx)

    ## 3. A change that breaks verification holds the lane; Revert removes it.
    attempt =
      run!(repo, "Create a file broken.txt containing exactly the text: BROKEN",
        writes: ["broken.txt"]
      )

    report("3 broken.txt", attempt)
    assert attempt.status == :held
    assert attempt.verify["output"] =~ "found BROKEN"
    assert :ok = Coordinator.revert(repo)
    refute File.exists?(Path.join(repo, "broken.txt"))
    assert_user_work_untouched(ctx)

    ## 4. A coordinator that dies mid-attempt: the next one recovers it; no blind retry.
    {:ok, started} =
      Coordinator.run_task(repo, %{
        title: "Partial work",
        goal:
          "First create a file partial.txt containing the text: started. " <>
            "Then run exactly this bash command: sleep 120. Then submit your result.",
        writes: ["partial.txt"]
      })

    assert eventually(fn -> File.exists?(Path.join(repo, "partial.txt")) end, 300_000)

    [{pid, _}] =
      Registry.lookup(Bm.Workspace.Registry, repo |> Bm.Runs.canonical_path() |> elem(1))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    assert Recovery.run() != []
    recovered = Runs.get_attempt!(started.id)
    report("4 recovery", recovered)
    assert recovered.status == :needs_reconciliation
    assert Enum.any?(recovered.actual_writes, &(&1["path"] == "partial.txt"))
    assert {_, 1} = System.cmd("pgrep", ["-f", "sleep 120"])
    assert_user_work_untouched(ctx)
  end

  defp run!(repo, goal, opts \\ []) do
    attrs = %{
      title: goal |> String.slice(0, 60),
      goal: goal,
      writes: Keyword.get(opts, :writes, []),
      verify_command: "sh check.sh"
    }

    {:ok, attempt} = Coordinator.run_task(repo, attrs)
    await_end(attempt.id)
  end

  defp await_end(id) do
    receive do
      {:workspace, _root, {:attempt, %{id: ^id, status: status} = attempt, _lane}}
      when status in [:accepted, :held, :failed, :cancelled, :needs_reconciliation] ->
        attempt

      {:workspace, _root, _event} ->
        await_end(id)
    after
      300_000 -> flunk("attempt #{id} did not finish")
    end
  end

  defp assert_user_work_untouched(%{repo: repo, cached: cached}) do
    assert git!(repo, ["diff", "--cached"]) == cached
    assert File.read!(Path.join(repo, "notes.txt")) == "user's unsaved notes\n"
    assert File.read!(Path.join(repo, "staged.txt")) == "user's staged change\n"
    assert git!(repo, ["log", "--format=%s"]) == "initial"
  end

  defp report(step, attempt) do
    IO.puts("""

    [milestone B] #{step}: #{attempt.status}#{if attempt.error, do: " — #{attempt.error}"}
      writes: #{inspect(Enum.map(attempt.actual_writes, & &1["path"]))}  flags: #{inspect(attempt.flags)}
      result: #{inspect(attempt.result)}
      tool calls: #{inspect(tool_calls(attempt))}
    """)
  end

  defp tool_calls(attempt) do
    import Ecto.Query

    Bm.Repo.all(
      from r in Bm.Bridge.Request,
        where: r.attempt_id == ^attempt.id and r.op == "authorize",
        order_by: r.id,
        select: {r.payload, r.outcome}
    )
    |> Enum.map(fn {payload, outcome} ->
      {payload["tool"], payload["input"]["path"] || payload["input"]["command"], outcome["allow"]}
    end)
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> receive(after: (500 -> do_eventually(fun, deadline)))
    end
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
end
