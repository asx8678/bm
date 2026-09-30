defmodule BmWeb.ChatLiveTest do
  # Not async: every connected ChatLive shares the "main" pi agent.
  use BmWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    Bm.Pi.subscribe("main")
    on_exit(fn -> Bm.Pi.stop("main") end)
  end

  defp connect(conn) do
    {:ok, view, _html} = live(conn, ~p"/chat")
    assert_receive {:pi, "main", :status, %{status: :idle}}, 5_000
    view
  end

  # Waits until the agent settles, then lets the LiveView catch up on its messages.
  defp wait_idle(view) do
    assert_receive {:pi, "main", :status, %{status: :idle}}, 5_000
    render(view)
  end

  test "renders the header, chat input and agent canvas", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")
    assert view |> element("#brand") |> render() =~ "BM"
    assert has_element?(view, "#chat-form textarea")
    assert has_element?(view, "#agent-flow[phx-hook=FlowCanvas]")
  end

  test "sending a message goes to pi and shows the reply", %{conn: conn} do
    view = connect(conn)

    view |> form("#chat-form", %{"text" => "hello agent"}) |> render_submit()
    html = wait_idle(view)

    assert html =~ "hello agent"
    assert html =~ "echo: hello agent"
  end

  test "tool calls show in the chat and update the agent node", %{conn: conn} do
    view = connect(conn)

    view |> form("#chat-form", %{"text" => "tool run"}) |> render_submit()
    html = wait_idle(view)

    assert html =~ "read"
    assert html =~ "mix.exs"
    assert_push_event(view, "flow:update_node", %{id: "agent", data: %{status: :running}})
    assert_push_event(view, "flow:update_node", %{id: "agent", data: %{tool: "read mix.exs"}})
  end

  test "blank messages are ignored", %{conn: conn} do
    view = connect(conn)

    view |> form("#chat-form", %{"text" => "   "}) |> render_submit()
    refute_receive {:pi, "main", {:user, _}, _}, 200
  end
end
