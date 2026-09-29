defmodule BmWeb.RunLiveTest do
  use BmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bm.WorkspaceFixtures

  alias Bm.Workspace.Coordinator

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = dir |> repo!() |> start_coordinator!()
    :ok = Coordinator.subscribe(repo)
    %{repo: repo}
  end

  defp done, do: %{submit: %{status: "done", summary: "Wrote the file."}}

  defp run_task!(repo, steps, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: "Write a file", goal: JSON.encode!(steps), verify_command: "true"},
        attrs
      )

    {:ok, attempt} = Coordinator.run_task(repo, attrs)
    %{run: run} = Bm.Runs.attempt_context(attempt)
    {run.id, attempt.id}
  end

  defp await_status(status) do
    receive do
      {:workspace, _root, {:attempt, %{status: ^status}, _lane}} -> :ok
      {:workspace, _root, _other} -> await_status(status)
    after
      10_000 -> flunk("attempt did not reach #{status}")
    end
  end

  # The page gets the same broadcasts; retry until it has rendered the change.
  defp eventually_has(view, selector, text, attempts \\ 100) do
    cond do
      has_element?(view, selector, text) -> true
      attempts == 0 -> flunk("#{selector} never showed #{inspect(text)}:\n" <> render(view))
      true -> receive(after: (20 -> eventually_has(view, selector, text, attempts - 1)))
    end
  end

  test "an accepted attempt shows its status, summary, verification, diff and spend",
       %{conn: conn, repo: repo} do
    {run_id, id} = run_task!(repo, [%{write: ["a.txt", "hello\n"]}, done()])
    await_status(:accepted)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")
    assert has_element?(view, "#run-goal", "Write a file")
    assert has_element?(view, "#attempt-#{id}-status", "Accepted")
    assert has_element?(view, "#attempts", "Wrote the file.")
    assert has_element?(view, "#verify-#{id}", "passed")
    assert has_element?(view, "#diff-#{id}", "a.txt")
    assert has_element?(view, "#diff-#{id}", "+hello")
    assert has_element?(view, "#run-spend", "$0.0030")
    assert has_element?(view, "#next-task-form")
    assert has_element?(view, "#revert-btn", "Revert last change")
  end

  test "updates live and stops a running attempt", %{conn: conn, repo: repo} do
    {run_id, id} = run_task!(repo, [%{hang: true}])
    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")
    await_status(:running)

    eventually_has(view, "#attempt-#{id}-status", "Running")
    view |> element("#stop-btn") |> render_click()
    eventually_has(view, "#attempt-#{id}-status", "Cancelled")
    eventually_has(view, "#actions", "Run")
  end

  test "a held attempt can be reverted", %{conn: conn, repo: repo} do
    {run_id, id} =
      run_task!(repo, [%{write: ["a.txt", "a\n"]}, done()], %{verify_command: "echo nope; exit 1"})

    await_status(:held)
    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")
    assert has_element?(view, "#attempt-#{id}-status", "Needs your decision")
    assert has_element?(view, "#verify-#{id}", "failed (exit 1)")
    assert has_element?(view, "#keep-btn")

    view |> element("#revert-btn") |> render_click()
    eventually_has(view, "#attempt-#{id}-status", "Reverted")
    refute File.exists?(Path.join(repo, "a.txt"))
  end

  test "a held attempt can be kept", %{conn: conn, repo: repo} do
    {run_id, id} =
      run_task!(repo, [%{write: ["a.txt", "a\n"]}, done()], %{verify_command: "false"})

    await_status(:held)
    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")

    view |> element("#keep-btn") |> render_click()
    eventually_has(view, "#attempt-#{id}-status", "Accepted")
    assert has_element?(view, "#attempts", "kept")
  end

  test "a refused revert says which files changed", %{conn: conn, repo: repo} do
    {run_id, _id} =
      run_task!(repo, [%{write: ["a.txt", "a\n"]}, done()], %{verify_command: "false"})

    await_status(:held)
    File.write!(Path.join(repo, "a.txt"), "the user's edit\n")
    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")

    view |> element("#revert-btn") |> render_click()
    assert has_element?(view, "#flash-error", "a.txt changed since the attempt")
    assert File.read!(Path.join(repo, "a.txt")) == "the user's edit\n"
  end

  test "runs the next task from the page, then finishes the run", %{conn: conn, repo: repo} do
    {run_id, _id} = run_task!(repo, [done()])
    await_status(:accepted)
    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")

    steps = JSON.encode!([%{write: ["b.txt", "b\n"]}, done()])
    view |> form("#next-task-form", next: %{goal: steps}) |> render_submit()
    await_status(:accepted)
    eventually_has(view, "#attempts", "b.txt")

    view |> element("#finish-run-btn") |> render_click()
    assert has_element?(view, "#run-status", "Done")
    assert has_element?(view, "#actions", "This run is finished")
  end

  test "a finished run links to a new task in the same repository", %{conn: conn, repo: repo} do
    {run_id, _id} = run_task!(repo, [done()])
    await_status(:accepted)
    {:ok, _run} = Coordinator.finish_run(repo)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")
    assert has_element?(view, "#new-task-link")
    refute has_element?(view, "#next-task-form")
  end

  test "an attempt shows its task text and checkpoint", %{conn: conn, repo: repo} do
    steps = [%{write: ["a.txt", "hello\n"]}, done()]
    {run_id, id} = run_task!(repo, steps, %{title: "Write a file", goal: JSON.encode!(steps)})
    await_status(:accepted)

    {:ok, view, _html} = live(conn, ~p"/runs/#{run_id}")
    assert has_element?(view, "#task-#{id}", "a.txt")
    assert has_element?(view, "#attempts", "refs/bm/runs/#{run_id}/1")
  end

  test "an unknown run goes back to Tasks", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/runs/999999")
  end
end
