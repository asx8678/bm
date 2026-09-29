defmodule Bm.Pi.Transcript do
  @moduledoc """
  Builds a chat transcript from agent events.

  The agent keeps its own copy and clients apply the same broadcast events,
  so both stay in step without resending the whole transcript.
  """

  @type entry ::
          %{role: :user | :assistant | :error | :notice, text: String.t()}
          | %{
              role: :tool,
              id: String.t(),
              name: String.t(),
              detail: String.t(),
              status: :running | :ok | :error
            }

  def apply(entries, {:user, text}), do: entries ++ [%{role: :user, text: text}]
  def apply(entries, :assistant_start), do: entries ++ [%{role: :assistant, text: ""}]

  def apply(entries, {:assistant_delta, delta}) do
    case List.last(entries) do
      %{role: :assistant} = last ->
        List.replace_at(entries, -1, %{last | text: last.text <> delta})

      _ ->
        entries ++ [%{role: :assistant, text: delta}]
    end
  end

  def apply(entries, {:tool_start, id, name, detail}) do
    entries ++ [%{role: :tool, id: id, name: name, detail: detail, status: :running}]
  end

  def apply(entries, {:tool_end, id, ok?}) do
    Enum.map(entries, fn
      %{role: :tool, id: ^id} = entry -> %{entry | status: if(ok?, do: :ok, else: :error)}
      entry -> entry
    end)
  end

  def apply(entries, {:error, text}), do: entries ++ [%{role: :error, text: text}]
  def apply(entries, {:notice, text}), do: entries ++ [%{role: :notice, text: text}]

  # Status-only updates leave the transcript unchanged.
  def apply(entries, :status), do: entries
end
