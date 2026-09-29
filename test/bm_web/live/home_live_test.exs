defmodule BmWeb.HomeLiveTest do
  use BmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bm.WorkspaceFixtures

  @moduletag :tmp_dir

  test "shows the task form and the empty run list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#task-form textarea[name='task[goal]']")
    assert has_element?(view, "#start-task-btn")
    assert has_element?(view, "#runs", "No runs yet.")
    assert has_element?(view, "#nav-tasks[aria-current=page]")
  end

  test "explains what is missing", %{conn: conn, tmp_dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#task-form", task: %{goal: "", path: dir}) |> render_submit()
    assert has_element?(view, "#task-form", "Describe the task.")

    view
    |> form("#task-form", task: %{goal: "Do it", path: Path.join(dir, "nope")})
    |> render_submit()

    assert has_element?(view, "#task-form", "No such directory.")

    outside = Path.join(System.tmp_dir!(), "bm-norepo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    view |> form("#task-form", task: %{goal: "Do it", path: outside}) |> render_submit()
    assert has_element?(view, "#task-form", "Not a git repository.")

    # The test's tmp_dir lies inside this project's own repository.
    view |> form("#task-form", task: %{goal: "Do it", path: dir}) |> render_submit()
    assert has_element?(view, "#task-form", "Not the top of a git repository")

    repo = repo!(dir)

    view
    |> form("#task-form", task: %{goal: "Do it", path: repo, verify_command: ""})
    |> render_submit()

    assert has_element?(view, "#task-form", "A verify command is required")
  end

  test "starting a task opens its run", %{conn: conn, tmp_dir: dir} do
    repo = dir |> repo!() |> start_coordinator!()
    {:ok, view, _html} = live(conn, ~p"/")

    steps =
      JSON.encode!([%{write: ["a.txt", "a\n"]}, %{submit: %{status: "done", summary: "ok"}}])

    assert {:error, {:live_redirect, %{to: "/runs/" <> run_id}}} =
             view
             |> form("#task-form", task: %{goal: steps, path: repo, verify_command: "true"})
             |> render_submit()

    {:ok, run_view, _html} = live(conn, ~p"/runs/#{run_id}")
    assert has_element?(run_view, "#run-goal")
  end
end
