defmodule Bm.Pi.ToolCalls do
  @moduledoc """
  Rebuilds tool calls from pi's streamed `toolcall_start` / `toolcall_delta` / `toolcall_end`
  events.

  Every call is observed at most twice:

    * `{:early, call}` as soon as its streamed argument JSON is complete. OpenAI-style providers
      (including GLM via zro) send `toolcall_end` for every call only after the whole message,
      so this lets the UI and read-only preparation react while the model is still writing.
    * `{:final, call}` at `toolcall_end`, with the provider's finalized arguments.

  Both are **proposals**. They never authorize anything: a planner's task becomes executable
  only through the BEAM's acceptance of the corresponding bridge request. Consumers reconcile
  the two observations by call id; the final arguments win.
  """

  defstruct calls: %{}

  @type call :: %{id: String.t() | nil, name: String.t() | nil, arguments: map()}
  @type observation :: {:early | :final, call}

  def new, do: %__MODULE__{}

  @doc "Applies one `assistantMessageEvent`; returns `{state, observations}`."
  @spec apply(%__MODULE__{}, map()) :: {%__MODULE__{}, [observation]}
  # pi's own tools need no early observation, and their arguments (a whole file for `write`)
  # can be large: decoding the growing buffer at every delta was quadratic (plan 36.10).
  @no_early ~w(read write edit bash grep find ls)

  def apply(state, %{"type" => "toolcall_start", "contentIndex" => index} = event) do
    call = %{
      id: event["id"],
      name: event["toolName"],
      buffer: "",
      early?: event["toolName"] in @no_early
    }

    {put_call(state, index, call), []}
  end

  def apply(state, %{"type" => "toolcall_delta", "contentIndex" => index, "delta" => delta})
      when is_binary(delta) do
    case Map.fetch(state.calls, index) do
      {:ok, %{early?: false} = call} ->
        call = %{call | buffer: call.buffer <> delta}

        # A JSON object can only be complete when the text ends with `}`.
        case String.ends_with?(String.trim_trailing(delta), "}") && JSON.decode(call.buffer) do
          {:ok, arguments} when is_map(arguments) ->
            {put_call(state, index, %{call | early?: true, buffer: ""}),
             [{:early, public(call, arguments)}]}

          _ ->
            {put_call(state, index, call), []}
        end

      _ ->
        {state, []}
    end
  end

  def apply(state, %{"type" => "toolcall_end", "contentIndex" => index, "toolCall" => tool_call}) do
    call = Map.get(state.calls, index) || %{id: nil, name: nil, buffer: "", early?: false}
    call = %{call | id: tool_call["id"] || call.id, name: tool_call["name"] || call.name}

    {%{state | calls: Map.delete(state.calls, index)},
     [{:final, public(call, tool_call["arguments"] || %{})}]}
  end

  def apply(state, _event), do: {state, []}

  defp public(call, arguments), do: %{id: call.id, name: call.name, arguments: arguments}

  defp put_call(state, index, call), do: %{state | calls: Map.put(state.calls, index, call)}
end
