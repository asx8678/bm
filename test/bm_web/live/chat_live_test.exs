defmodule BmWeb.ChatLiveTest do
  # Not async: every connected ChatLive shares the one Bm.Chat agent.
  use BmWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the header, repository picker, chat input and agent canvas", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")
    assert view |> element("#brand") |> render() =~ "BM"
    assert has_element?(view, "#repo-form #repo-input")
    assert has_element?(view, "#chat-form textarea")
    assert has_element?(view, "#agent-flow[phx-hook=FlowCanvas]")
  end
end
