defmodule Mix.Tasks.Bm.Bench do
  @shortdoc "Mini-benchmark: plain pi vs BM with one worker (real model, costs money)"

  @moduledoc """
  Runs the same small tasks twice, each in a fresh copy of a tiny Python project:

    * **plain pi**: pi with the user's own setup, no BM control; afterwards the task's check runs;
    * **BM**: one guarded worker through the workspace coordinator, with the check as the verify
      command.

  Records verified success, cost, wall time and whether a decision was needed in
  `docs/BENCHMARK.md` (plan step 6.5).

      mix bm.bench            # all tasks
      mix bm.bench greet      # only the named tasks
  """

  use Mix.Task

  alias Bm.Runs
  alias Bm.Workspace.Coordinator

  @model "zro/glm-5.3"
  @session_timeout 600_000

  @files %{
    ".gitignore" => "__pycache__/\n",
    "README.md" => "A tiny project for BM's benchmark.\n",
    "calc.py" => """
    def add(a, b):
        return a - b


    def mul(a, b):
        return a * b
    """,
    "text.py" => """
    def word_count(s):
        return len(s.split(" "))
    """
  }

  @tasks [
    {"greet", "Create hello.py with a function greet(name) that returns 'Hello, <name>!'.",
     ~s|python3 -c "from hello import greet; assert greet('Ann') == 'Hello, Ann!'"|},
    {"fix_add", "Fix the bug in calc.py: add(a, b) must return the sum of a and b.",
     ~s|python3 -c "from calc import add, mul; assert add(2, 3) == 5 and mul(2, 3) == 6"|},
    {"is_prime",
     "Add a function is_prime(n) to calc.py that returns True for prime numbers and False " <>
       "otherwise (numbers below 2 are not prime).",
     ~s|python3 -c "from calc import is_prime; assert [n for n in range(20) if is_prime(n)] == [2, 3, 5, 7, 11, 13, 17, 19]"|},
    {"word_count",
     "Fix word_count in text.py so that it counts words separated by any whitespace, including " <>
       "repeated spaces, tabs and newlines. An empty string has 0 words.",
     ~s|python3 -c "from text import word_count as w; assert w('a  b\\tc\\nd') == 4 and w('') == 0 and w('  x ') == 1"|},
    {"cli",
     "Make `python3 calc.py 4 5` print the product of the two numbers (20), and nothing else.",
     ~s|test "$(python3 calc.py 4 5)" = "20"|}
  ]

  @impl true
  def run(args) do
    # This process must not recover attempts that belong to a running dev server.
    Application.put_env(:bm, :recover_on_start, false)
    Mix.Task.run("app.start")
    Logger.configure(level: :info)

    tasks = if args == [], do: @tasks, else: Enum.filter(@tasks, &(elem(&1, 0) in args))

    results =
      for {key, goal, check} <- tasks, mode <- [:plain_pi, :bm] do
        Mix.shell().info("#{key} / #{mode} …")
        result = run_one(mode, key, goal, check)
        Mix.shell().info("  #{inspect(result)}")
        Map.merge(result, %{key: key, mode: mode})
      end

    File.write!("docs/BENCHMARK.md", report(results))
    Mix.shell().info("Wrote docs/BENCHMARK.md")
  end

  defp run_one(mode, key, goal, check) do
    dir = fixture!(key, mode)
    started = System.monotonic_time(:millisecond)

    result =
      case mode do
        :plain_pi -> plain_pi(dir, goal, check)
        :bm -> bm(dir, goal, check)
      end

    File.rm_rf!(dir)

    Map.put(result, :seconds, (System.monotonic_time(:millisecond) - started) / 1000)
  end

  ## Plain pi: the user's own pi, then the same check

  defp plain_pi(dir, goal, check) do
    id = "bench-#{System.unique_integer([:positive])}"
    Bm.Pi.subscribe(id)

    {:ok, _} =
      Bm.Pi.ensure_agent(id,
        command: ["pi", "--mode", "rpc", "--no-session", "--model", @model],
        cwd: dir
      )

    :ok = await_status(id, :idle)
    :ok = Bm.Pi.prompt(id, goal <> "\nWhen you are done, reply with one sentence.")
    finished = await_settled(id)
    spend = Bm.Pi.snapshot(id).summary.spend
    Bm.Pi.stop(id)

    {_, status} = System.cmd("sh", ["-c", check], cd: dir, stderr_to_stdout: true)

    %{
      verified: finished == :ok and status == 0,
      cost: spend.confirmed,
      unknown: spend.unknown,
      outcome: if(finished == :ok, do: "check exit #{status}", else: "no answer in time"),
      decision: false
    }
  end

  defp await_status(id, status) do
    receive do
      {:pi, ^id, :status, %{status: ^status}} -> :ok
      {:pi, ^id, _, _} -> await_status(id, status)
    after
      @session_timeout -> :timeout
    end
  end

  defp await_settled(id) do
    receive do
      {:pi, ^id, :status, %{status: :running}} -> await_status(id, :idle)
      {:pi, ^id, _, _} -> await_settled(id)
    after
      @session_timeout -> :timeout
    end
  end

  ## BM: one guarded worker, the check as verify command

  defp bm(dir, goal, check) do
    {:ok, _} = Coordinator.ensure_started(dir)
    :ok = Coordinator.subscribe(dir)
    title = goal |> String.split(".") |> hd() |> String.slice(0, 70)

    result =
      case Coordinator.run_task(dir, %{title: title, goal: goal, verify_command: check}) do
        {:ok, attempt} ->
          ended = await_attempt(attempt.id)
          %{run: run} = Runs.attempt_context(ended)
          Coordinator.finish_run(dir)

          %{
            verified: ended.status == :accepted,
            cost: run.spent_usd,
            unknown: run.spent_unknown,
            outcome: "#{ended.status}#{if ended.error, do: ": #{ended.error}"}",
            decision:
              ended.status in [:held, :needs_reconciliation] or
                (ended.status in [:failed, :cancelled] and ended.actual_writes != [])
          }

        {:error, reason} ->
          %{
            verified: false,
            cost: 0.0,
            unknown: 0,
            outcome: "not started: #{inspect(reason)}",
            decision: false
          }
      end

    Coordinator.stop(dir)
    result
  end

  defp await_attempt(id) do
    receive do
      {:workspace, _, {:attempt, %{id: ^id, status: status} = attempt, _lane}}
      when status in [:accepted, :held, :failed, :cancelled, :needs_reconciliation] ->
        attempt

      {:workspace, _, _} ->
        await_attempt(id)
    after
      @session_timeout -> Runs.get_attempt!(id)
    end
  end

  ## Fixture and report

  defp fixture!(key, mode) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bm-bench-#{key}-#{mode}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    for {name, content} <- @files, do: File.write!(Path.join(dir, name), content)

    for args <- [~w(init -q -b main), ~w(add -A), ~w(commit -q -m initial)] do
      {_, 0} =
        System.cmd("git", ["-c", "user.name=B", "-c", "user.email=b@example.com" | args], cd: dir)
    end

    dir
  end

  defp report(results) do
    rows =
      Enum.map_join(results, "\n", fn r ->
        "| #{r.key} | #{mode_name(r.mode)} | #{if r.verified, do: "yes", else: "no"} | " <>
          "#{money(r.cost)}#{if r.unknown > 0, do: " + #{r.unknown} unknown"} | " <>
          "#{Float.round(r.seconds, 1)} s | #{if r.decision, do: "yes", else: "no"} | " <>
          "#{String.replace(r.outcome, "|", "/") |> String.slice(0, 120)} |"
      end)

    totals =
      results
      |> Enum.group_by(& &1.mode)
      |> Enum.map_join("\n", fn {mode, rs} ->
        "| #{mode_name(mode)} | #{Enum.count(rs, & &1.verified)} / #{length(rs)} | " <>
          "#{money(Enum.sum_by(rs, & &1.cost))} | #{rs |> Enum.sum_by(& &1.seconds) |> Float.round(1)} s | " <>
          "#{Enum.count(rs, & &1.decision)} |"
      end)

    """
    # BM benchmark

    Generated by `mix bm.bench` on #{Date.utc_today()} with #{@model}. Each task ran in a fresh
    copy of a tiny Python project. **Plain pi** is pi with the user's own setup and no BM control;
    its result is checked afterwards with the same command. **BM** is one guarded worker; the
    check is its verify command, and only an accepted attempt counts as verified. "Decision" means
    the attempt left changes that wait for the user (Keep or Revert). Findings and decisions
    from these numbers are recorded in IMPLEMENTATION_PLAN.md (Phase 6 status).

    ## Totals

    | Mode | Verified | Cost | Wall time | Decisions |
    |---|---|---|---|---|
    #{totals}

    ## Tasks

    | Task | Mode | Verified | Cost | Time | Decision | Outcome |
    |---|---|---|---|---|---|---|
    #{rows}
    """
  end

  defp mode_name(:plain_pi), do: "plain pi"
  defp mode_name(:bm), do: "BM"

  defp money(amount), do: "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 4)
end
