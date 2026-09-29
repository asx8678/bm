defmodule Bm.Pi.ToolCalls do
  @moduledoc """
  Rebuilds tool calls from pi's streamed `toolcall_start` / `toolcall_delta` /
  `toolcall_end` events and reports each call as soon as its arguments are complete.

  OpenAI-style providers only send `toolcall_end` for every call after the whole
  assistant message has streamed. Parsing the accumulated argument deltas lets a
  call be acted on while the model is still writing the next one: a JSON object
  only decodes once its closing brace has arrived.
  """

  defstruct calls: %{}

  @type ready :: %{id: String.t(), name: String.t(), arguments: map()}

  def new, do: %__MODULE__{}

  @doc """
  Applies one `assistantMessageEvent`. Returns `{state, ready}` where `ready` lists
  the calls whose arguments became complete with this event (at most one).
  """
  def apply(state, %{"type" => "toolcall_start", "contentIndex" => index} = event) do
    call = %{id: event["id"], name: event["toolName"], buffer: "", done?: false}
    {%{state | calls: Map.put(state.calls, index, call)}, []}
  end

  def apply(state, %{"type" => "toolcall_delta", "contentIndex" => index, "delta" => delta})
      when is_binary(delta) do
    case Map.fetch(state.calls, index) do
      {:ok, %{done?: false} = call} ->
        call = %{call | buffer: call.buffer <> delta}

        case JSON.decode(call.buffer) do
          {:ok, arguments} when is_map(arguments) -> finish(state, index, call, arguments)
          _ -> {put_call(state, index, call), []}
        end

      _ ->
        {state, []}
    end
  end

  def apply(state, %{"type" => "toolcall_end", "contentIndex" => index, "toolCall" => tool_call}) do
    case Map.get(state.calls, index) do
      %{done?: true} ->
        {state, []}

      call ->
        call = call || %{id: nil, name: nil, buffer: "", done?: false}

        call = %{
          call
          | id: call.id || tool_call["id"],
            name: call.name || tool_call["name"]
        }

        finish(state, index, call, tool_call["arguments"] || %{})
    end
  end

  def apply(state, _event), do: {state, []}

  defp finish(state, index, call, arguments) do
    ready = %{id: call.id, name: call.name, arguments: arguments}
    {put_call(state, index, %{call | done?: true, buffer: ""}), [ready]}
  end

  defp put_call(state, index, call), do: %{state | calls: Map.put(state.calls, index, call)}
end
