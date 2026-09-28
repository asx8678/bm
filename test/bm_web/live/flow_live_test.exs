defmodule BmWeb.FlowLiveTest do
  use BmWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the flow canvas with the initial graph", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/flow")
    assert has_element?(view, "#flow-canvas[phx-hook=FlowCanvas]")
    assert html =~ "3 nodes · 2 edges"
  end

  test "client edits update the graph", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow")

    html =
      render_hook(view, "flow_changed", %{
        "nodes" => [%{"id" => "1", "position" => %{"x" => 0, "y" => 0}, "data" => %{}}],
        "edges" => []
      })

    assert html =~ "1 nodes · 0 edges"
  end

  test "reset restores the initial graph and pushes it to the client", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow")
    render_hook(view, "flow_changed", %{"nodes" => [], "edges" => []})

    assert view |> element("button", "Reset") |> render_click() =~ "3 nodes · 2 edges"
    assert_push_event(view, "flow:set_graph", %{nodes: [_, _, _]})
  end
end
