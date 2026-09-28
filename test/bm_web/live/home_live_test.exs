defmodule BmWeb.HomeLiveTest do
  use BmWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the header and chat input", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "BM"
    assert html =~ "coding"
    assert has_element?(view, "#chat-form textarea")
  end

  test "sending a message shows it in the conversation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("#chat-form", %{"text" => "hello agent"}) |> render_submit()
    assert html =~ "hello agent"
  end

  test "blank messages are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("#chat-form", %{"text" => "   "}) |> render_submit()
    refute html =~ "Thinking"
  end
end
