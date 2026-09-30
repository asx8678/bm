defmodule Bm.PlanTest do
  use ExUnit.Case, async: true

  alias Bm.Plan
  alias Bm.Runs.Task

  @root "/work/repo"

  defp task(key, status, opts \\ []) do
    %Task{
      key: key,
      status: status,
      revision: Keyword.get(opts, :revision, 1),
      depends_on: Keyword.get(opts, :depends_on, [])
    }
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{tasks: [], user_owned: ["notes.txt"], root: @root, budget_left: nil, plan_open: true},
      overrides
    )
  end

  defp proposal(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "health",
        "title" => "Add a health endpoint",
        "goal" => "Add GET /health returning ok.",
        "mutates" => true,
        "writes" => ["lib/health.ex", "./test/health_test.exs"],
        "done_when" => "The test passes."
      },
      overrides
    )
  end

  test "a good proposal becomes task attributes, with paths normalized" do
    assert {:ok, attrs} = Plan.validate(proposal(%{"check" => " mix test "}), ctx())
    assert attrs.key == "health"
    assert attrs.revision == 1
    assert attrs.writes == ["lib/health.ex", "test/health_test.exs"]
    assert attrs.depends_on == []
    assert attrs.check == "mix test"
    assert attrs.mutates
  end

  test "a read-only task needs no writes" do
    assert {:ok, %{mutates: false, writes: []}} =
             Plan.validate(proposal(%{"mutates" => false, "writes" => []}), ctx())
  end

  describe "rejections" do
    # {description, proposal overrides, ctx overrides, expected text in the reason}
    @cases [
      {"plan closed", %{}, %{plan_open: false}, "plan is closed"},
      {"budget spent", %{}, %{budget_left: 0.0}, "budget is spent"},
      {"missing key", %{"key" => nil}, %{}, "`key` is required"},
      {"empty title", %{"title" => "  "}, %{}, "`title` must not be empty"},
      {"title too long", %{"title" => String.duplicate("t", 201)}, %{}, "too long"},
      {"missing goal", %{"goal" => nil}, %{}, "`goal` is required"},
      {"mutates missing", %{"mutates" => nil}, %{}, "`mutates` is required"},
      {"mutates not boolean", %{"mutates" => "yes"}, %{}, "true or false"},
      {"writes not a list", %{"writes" => "lib/a.ex"}, %{}, "list of strings"},
      {"bad key", %{"key" => "Health-Check"}, %{}, "not valid"},
      {"no writes for a mutating task", %{"writes" => []}, %{}, "must list them"},
      {"writes on a read-only task", %{"mutates" => false}, %{}, "must not declare"},
      {"write outside", %{"writes" => ["../other/x.ex"]}, %{}, "outside the workspace"},
      {"absolute write outside", %{"writes" => ["/etc/hosts"]}, %{}, "outside the workspace"},
      {"write into .git", %{"writes" => [".git/config"]}, %{}, "inside .git"},
      {"user's file", %{"writes" => ["notes.txt"]}, %{}, "uncommitted changes"},
      {"unknown dependency", %{"depends_on" => ["setup"]}, %{}, "not a task in this run"},
      {"self dependency", %{"depends_on" => ["health"]}, %{}, "depend on itself"}
    ]

    for {description, overrides, ctx_overrides, expected} <- @cases do
      test description do
        assert {:error, reason} =
                 Plan.validate(
                   proposal(unquote(Macro.escape(overrides))),
                   ctx(unquote(Macro.escape(ctx_overrides)))
                 )

        assert reason =~ unquote(expected)
      end
    end

    test "a used key" do
      assert {:error, reason} =
               Plan.validate(proposal(), ctx(%{tasks: [task("health", :queued)]}))

      assert reason =~ "already used"
    end

    test "a dependency that failed" do
      tasks = [task("setup", :failed)]

      assert {:error, reason} =
               Plan.validate(proposal(%{"depends_on" => ["setup"]}), ctx(%{tasks: tasks}))

      assert reason =~ "setup failed"
    end

    test "not a map" do
      assert {:error, _} = Plan.validate("health", ctx())
    end
  end

  describe "re-plans" do
    test "a failed task may be proposed again once, as revision 2" do
      tasks = [task("health", :failed)]
      assert {:ok, %{revision: 2}} = Plan.validate(proposal(), ctx(%{tasks: tasks}))
    end

    test "not a second time" do
      tasks = [task("health", :failed), task("health", :failed, revision: 2)]
      assert {:error, reason} = Plan.validate(proposal(), ctx(%{tasks: tasks}))
      assert reason =~ "already re-planned once"
    end

    test "a dependency on a re-planned task follows its latest revision" do
      tasks = [task("setup", :failed), task("setup", :queued, revision: 2)]

      assert {:ok, %{depends_on: ["setup"]}} =
               Plan.validate(proposal(%{"depends_on" => ["setup"]}), ctx(%{tasks: tasks}))
    end
  end

  describe "cycles" do
    test "a three-task cycle is found" do
      assert Plan.cycle(%{"a" => ["c"], "b" => ["a"], "c" => ["b"]}) in [
               ["a", "c", "b", "a"],
               ["b", "a", "c", "b"],
               ["c", "b", "a", "c"]
             ]
    end

    test "a diamond is not a cycle; unknown keys are ignored" do
      assert Plan.cycle(%{"a" => [], "b" => ["a"], "c" => ["a"], "d" => ["b", "c", "zzz"]}) == nil
    end

    test "a proposal that would close a cycle is rejected" do
      # Only possible when an existing task already names the new key (defensive check).
      tasks = [task("a", :queued, depends_on: ["health"])]

      assert {:error, reason} =
               Plan.validate(proposal(%{"depends_on" => ["a"]}), ctx(%{tasks: tasks}))

      assert reason =~ "cycle"
    end
  end
end
