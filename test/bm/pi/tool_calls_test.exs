defmodule Bm.Pi.ToolCallsTest do
  use ExUnit.Case, async: true

  alias Bm.Pi.ToolCalls

  defp run(events) do
    {observations, _state} =
      Enum.map_reduce(events, ToolCalls.new(), fn event, state ->
        {state, observed} = ToolCalls.apply(state, event)
        {observed, state}
      end)

    observations
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

  defp finish(index, id, arguments),
    do: %{
      "type" => "toolcall_end",
      "contentIndex" => index,
      "toolCall" => %{"id" => id, "name" => "add_task", "arguments" => arguments}
    }

  test "a call is observed early as soon as its argument JSON is complete" do
    assert run([
             start(0, "call-a"),
             delta(0, ~s({"id":"a","ti)),
             delta(0, ~s(tle":"A"})),
             start(1, "call-b"),
             delta(1, ~s({"id":"b"}))
           ]) == [
             [],
             [],
             [
               {:early,
                %{id: "call-a", name: "add_task", arguments: %{"id" => "a", "title" => "A"}}}
             ],
             [],
             [{:early, %{id: "call-b", name: "add_task", arguments: %{"id" => "b"}}}]
           ]
  end

  test "toolcall_end always yields a final observation with the provider's arguments" do
    observed =
      run([start(0, "call-a"), delta(0, ~s({"id":"a"})), finish(0, "call-a", %{"id" => "a2"})])

    assert List.flatten(observed) == [
             {:early, %{id: "call-a", name: "add_task", arguments: %{"id" => "a"}}},
             {:final, %{id: "call-a", name: "add_task", arguments: %{"id" => "a2"}}}
           ]
  end

  test "a call whose deltas never parsed is only observed at the end" do
    observed =
      run([start(0, "call-a"), delta(0, ~s({"id":)), finish(0, "call-a", %{"id" => "a"})])

    assert List.flatten(observed) == [
             {:final, %{id: "call-a", name: "add_task", arguments: %{"id" => "a"}}}
           ]
  end

  test "interleaved calls are tracked separately by content index" do
    observed =
      run([start(0, "x"), start(1, "y"), delta(1, ~s({"id":"y"})), delta(0, ~s({"id":"x"}))])

    assert observed |> List.flatten() |> Enum.map(fn {:early, call} -> call.id end) == ["y", "x"]
  end
end
