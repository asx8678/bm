defmodule Bm.Pi.Agent do
  @moduledoc """
  One pi coding agent: owns a `pi --mode rpc` OS process through a Port.

  Commands go to pi's stdin as JSON lines; responses and session events come back
  on stdout (see pi's docs/rpc.md). Events are reduced into a transcript and a
  summary and broadcast through `Bm.Pi`. If pi exits, the agent stays up in the
  `:exited` state and the next prompt starts a fresh pi process.
  """

  use GenServer, restart: :transient

  require Logger

  alias Bm.Pi.ToolCalls
  alias Bm.Pi.Transcript

  # pi dialogs block until answered; this client has no dialog UI yet, so it declines them.
  @dialog_methods ~w(select confirm input editor)
  @max_line_bytes 16 * 1024 * 1024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Bm.Pi.via(Keyword.fetch!(opts, :id)))
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:bm, Bm.Pi, [])

    state = %{
      id: Keyword.fetch!(opts, :id),
      command: opts[:command] || Keyword.fetch!(config, :command),
      cwd: opts[:cwd] || config[:cwd] || File.cwd!(),
      # Extra OS environment for the pi process, e.g. %{"PI_FABRIC_DEPTH" => "99"}.
      env: opts[:env] || config[:env] || %{},
      # When set, every stdout line from pi is appended to this file (for debugging and replay).
      raw_log: opts[:raw_log],
      tool_calls: ToolCalls.new(),
      port: nil,
      buffer: "",
      status: :starting,
      model: nil,
      tool: nil,
      usage: nil,
      transcript: [],
      next_id: 1,
      pending: %{}
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: {:noreply, open_port(state)}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{transcript: state.transcript, summary: summary(state)}, state}
  end

  def handle_call({:prompt, text}, _from, state) do
    state = if state.port, do: state, else: open_port(state)

    if state.port do
      command =
        if state.status == :running,
          do: %{type: "prompt", message: text, streamingBehavior: "followUp"},
          else: %{type: "prompt", message: text}

      {:reply, :ok, state |> emit({:user, text}) |> send_command(command)}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call(:new_session, _from, %{port: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:new_session, _from, state) do
    state = %{state | tool_calls: ToolCalls.new()}
    {:reply, :ok, state |> emit(:reset) |> send_command(%{type: "new_session"})}
  end

  def handle_call(:abort, _from, %{port: nil} = state), do: {:reply, :ok, state}
  def handle_call(:abort, _from, state), do: {:reply, :ok, send_command(state, %{type: "abort"})}

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = String.trim_trailing(state.buffer <> chunk, "\r")
    {:noreply, handle_line(%{state | buffer: ""}, line)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = %{state | port: nil, buffer: "", status: :exited, tool: nil, pending: %{}}

    {:noreply,
     emit(state, {:error, "pi exited with status #{code}. Send a message to restart it."})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    # Closing stdin asks pi to shut down cleanly.
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_port(state) do
    [executable | args] = state.command

    case System.find_executable(executable) do
      nil ->
        emit(
          %{state | status: :exited},
          {:error, "Cannot start pi: #{executable} not found in PATH."}
        )

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            {:line, @max_line_bytes},
            {:args, args},
            {:cd, state.cwd},
            {:env, Enum.map(state.env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
          ])

        %{state | port: port, status: :starting}
        |> emit(:status)
        |> send_command(%{type: "get_state"})
    end
  end

  defp send_command(state, command) do
    id = "bm-#{state.next_id}"
    Port.command(state.port, [JSON.encode!(Map.put(command, :id, id)), "\n"])
    %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, id, command.type)}
  end

  defp send_record(state, record) do
    Port.command(state.port, [JSON.encode!(record), "\n"])
    state
  end

  defp handle_line(state, ""), do: state

  defp handle_line(state, line) do
    if state.raw_log, do: File.write(state.raw_log, [line, "\n"], [:append])

    case JSON.decode(line) do
      {:ok, record} when is_map(record) ->
        handle_record(state, record)

      _ ->
        Logger.warning(
          "pi agent #{state.id}: ignoring non-JSON output: #{String.slice(line, 0, 200)}"
        )

        state
    end
  end

  defp handle_record(state, %{"type" => "response"} = response) do
    {command, pending} = Map.pop(state.pending, response["id"])
    state = %{state | pending: pending}

    cond do
      response["success"] == false ->
        emit(state, {:error, "pi #{response["command"]} failed: #{response["error"]}"})

      command == "get_state" ->
        data = response["data"] || %{}
        status = if(data["isStreaming"], do: :running, else: :idle)
        emit(%{state | model: model_name(data["model"]), status: status}, :status)

      true ->
        state
    end
  end

  defp handle_record(state, %{"type" => "agent_start"}),
    do: emit(%{state | status: :running}, :status)

  defp handle_record(state, %{"type" => "agent_settled"}),
    do: emit(%{state | status: :idle, tool: nil}, :status)

  defp handle_record(state, %{"type" => "message_start", "message" => %{"role" => "assistant"}}),
    do: emit(%{state | tool_calls: ToolCalls.new()}, :assistant_start)

  defp handle_record(state, %{"type" => "message_update"} = record) do
    state = if usage = record["usage"], do: %{state | usage: usage_summary(usage)}, else: state

    case record["assistantMessageEvent"] do
      %{"type" => "text_delta", "delta" => delta} ->
        emit(state, {:assistant_delta, delta})

      %{"type" => "toolcall_" <> _} = event ->
        {tool_calls, ready} = ToolCalls.apply(state.tool_calls, event)
        Enum.reduce(ready, %{state | tool_calls: tool_calls}, &emit(&2, {:tool_call_ready, &1}))

      _ ->
        state
    end
  end

  defp handle_record(state, %{
         "type" => "message_end",
         "message" => %{"role" => "assistant"} = message
       }) do
    case message["stopReason"] do
      "error" -> emit(state, {:error, short_error(message["errorMessage"])})
      "aborted" -> emit(state, {:notice, "Stopped."})
      _ -> state
    end
  end

  defp handle_record(state, %{"type" => "tool_execution_start"} = record) do
    detail = tool_detail(record["toolName"], record["args"])
    state = %{state | tool: String.trim("#{record["toolName"]} #{detail}")}
    emit(state, {:tool_start, record["toolCallId"], record["toolName"], detail})
  end

  defp handle_record(state, %{"type" => "tool_execution_end"} = record) do
    emit(%{state | tool: nil}, {:tool_end, record["toolCallId"], record["isError"] != true})
  end

  defp handle_record(state, %{"type" => "auto_retry_start"} = record) do
    emit(
      state,
      {:notice,
       "Retrying (#{record["attempt"]}/#{record["maxAttempts"]}): #{record["errorMessage"]}"}
    )
  end

  defp handle_record(state, %{"type" => "extension_ui_request", "method" => method} = request)
       when method in @dialog_methods do
    state
    |> send_record(%{type: "extension_ui_response", id: request["id"], cancelled: true})
    |> emit({:notice, "Declined pi dialog: #{request["title"] || method}"})
  end

  # The bm_bridge extension reports its tool calls as `bm:`-prefixed notify records.
  defp handle_record(
         state,
         %{"type" => "extension_ui_request", "method" => "notify", "message" => "bm:" <> json}
       ) do
    case JSON.decode(json) do
      {:ok, %{"event" => event, "data" => data}} -> emit(state, {:bridge, event, data})
      _ -> state
    end
  end

  defp handle_record(state, %{"type" => "extension_error"} = record) do
    emit(state, {:notice, "pi extension error: #{record["error"]}"})
  end

  defp handle_record(state, _record), do: state

  defp emit(state, event) do
    state = %{state | transcript: Transcript.apply(state.transcript, event)}
    Bm.Pi.broadcast(state.id, event, summary(state))
    state
  end

  defp summary(state) do
    %{
      status: state.status,
      model: state.model,
      tool: state.tool,
      usage: state.usage,
      cwd: state.cwd
    }
  end

  # Provider errors can carry request details and a stack trace; keep the readable part.
  defp short_error(message) when is_binary(message) and message != "" do
    message |> String.split("; details=") |> hd() |> String.split("\n") |> hd()
  end

  defp short_error(_message), do: "The model request failed."

  defp model_name(%{"name" => name}), do: name
  defp model_name(%{"id" => id}), do: id
  defp model_name(_), do: nil

  defp usage_summary(usage) do
    %{
      input: usage["input"] || 0,
      output: usage["output"] || 0,
      cache_read: usage["cacheRead"] || 0
    }
  end

  defp tool_detail(_name, %{"command" => command}) when is_binary(command), do: truncate(command)
  defp tool_detail(_name, %{"path" => path}) when is_binary(path), do: truncate(path)

  defp tool_detail(_name, args) when is_map(args) and map_size(args) > 0,
    do: truncate(JSON.encode!(args))

  defp tool_detail(_name, _args), do: ""

  defp truncate(text) do
    text = text |> String.split(["\r\n", "\n"], trim: true) |> Enum.join(" ")
    if String.length(text) > 80, do: String.slice(text, 0, 77) <> "...", else: text
  end
end
