defmodule Bm.Pi.ToolCallsTest do
  use ExUnit.Case, async: true

  alias Bm.Pi.ToolCalls

  defp run(events), do: Enum.map_reduce(events, ToolCalls.new(), &flip_apply/2)

  defp flip_apply(event, state) do
    {state, ready} = ToolCalls.apply(state, event)
    {ready, state}
  end

  defp start(index, id),
    do: %{
      "type" => "toolcall_start",
      "contentIndex" => index,
      "id" => id,
      "toolName" => "add_task"
    }

  defp delta(index, text),
    do: %{"type" => "toolcall_delta", "contentIndex" => index, "delta" => text}

  test "a call is ready as soon as its argument JSON is complete, before toolcall_end" do
    {ready_per_event, _state} =
      run([
        start(0, "call-a"),
        delta(0, ~s({"id":"a","ti)),
        delta(0, ~s(tle":"A"})),
        start(1, "call-b"),
        delta(1, ~s({"id":"b"}))
      ])

    assert ready_per_event == [
             [],
             [],
             [%{id: "call-a", name: "add_task", arguments: %{"id" => "a", "title" => "A"}}],
             [],
             [%{id: "call-b", name: "add_task", arguments: %{"id" => "b"}}]
           ]
  end

  test "toolcall_end does not report a call twice" do
    end_event = %{
      "type" => "toolcall_end",
      "contentIndex" => 0,
      "toolCall" => %{"id" => "call-a", "name" => "add_task", "arguments" => %{"id" => "a"}}
    }

    {ready_per_event, _} = run([start(0, "call-a"), delta(0, ~s({"id":"a"})), end_event])
    assert ready_per_event |> List.flatten() |> length() == 1
  end

  test "toolcall_end reports calls whose deltas never parsed, using the final arguments" do
    end_event = %{
      "type" => "toolcall_end",
      "contentIndex" => 0,
      "toolCall" => %{"id" => "call-a", "name" => "add_task", "arguments" => %{"id" => "a"}}
    }

    {ready_per_event, _} = run([start(0, "call-a"), delta(0, ~s({"id":)), end_event])

    assert List.last(ready_per_event) == [
             %{id: "call-a", name: "add_task", arguments: %{"id" => "a"}}
           ]
  end

  test "interleaved calls are tracked separately by content index" do
    {ready_per_event, _} =
      run([
        start(0, "x"),
        start(1, "y"),
        delta(1, ~s({"id":"y"})),
        delta(0, ~s({"id":"x"}))
      ])

    assert ready_per_event |> List.flatten() |> Enum.map(& &1.id) == ["y", "x"]
  end
end
