defmodule Bm.Pi.Agent do
  @moduledoc """
  Agent adapter: owns one `pi --mode rpc` OS process through a Port.

  Commands go to pi's stdin as JSON lines; responses and session events come back on stdout
  (see pi's docs/rpc.md). Commands issued through the public API wait for pi's correlated
  response, so `:ok` means pi accepted the command.

  Events are reduced into a transcript and a summary and broadcast through `Bm.Pi`:

    * `{:tool_call, :early | :final, call}` - streamed tool calls. These are **proposals**;
      nothing may act on them as an authorization.
    * `{:bridge, event, data}` - best-effort telemetry from BM extensions (`bm:` notify).

  Authoritative requests from BM extensions arrive as `bm:` input dialogs. They are forwarded
  to the agent's `:owner` process as `{:pi_request, agent_id, request}`; the owner answers with
  `Bm.Pi.respond/3`. Without an owner they are rejected, so tools fail closed.

  If pi exits, the adapter stays up in the `:exited` state and the next prompt starts a fresh
  pi process with a new session epoch.
  """

  # Leave time for pi to shut down gracefully before the supervisor gives up (see terminate/2).
  use GenServer, restart: :transient, shutdown: 20_000

  require Logger

  alias Bm.Pi.ToolCalls
  alias Bm.Pi.Transcript

  # pi dialogs block until answered. Other extensions' dialogs go to the owner when the agent
  # was started with `approvals: true` (a worker's attempt, plan 24.1); otherwise declined.
  @dialog_methods ~w(select confirm input editor)
  @max_line_bytes 16 * 1024 * 1024
  @max_buffer_bytes 32 * 1024 * 1024
  @max_raw_log_bytes 64 * 1024 * 1024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Bm.Pi.via(Keyword.fetch!(opts, :id)))
  end

  @impl true
  def init(opts) do
    # Needed for terminate/2 to run on supervisor shutdown, so pi can exit gracefully.
    Process.flag(:trap_exit, true)
    config = Application.get_env(:bm, Bm.Pi, [])
    owner = opts[:owner]
    if owner, do: Process.monitor(owner)

    state = %{
      id: Keyword.fetch!(opts, :id),
      command: opts[:command] || Keyword.fetch!(config, :command),
      cwd: opts[:cwd] || config[:cwd] || File.cwd!(),
      # Extra OS environment for the pi process, e.g. %{"PI_FABRIC_DEPTH" => "99"}.
      env: opts[:env] || config[:env] || %{},
      # When set, stdout lines from pi are appended to this file (debugging and replay fixtures).
      raw_log: opts[:raw_log],
      raw_log_bytes: 0,
      # Extension command that makes pi exit cleanly (profiles with a bm_* extension set it).
      shutdown_command: opts[:shutdown_command],
      owner: owner,
      # Forward other extensions' dialogs to the owner for the user (plan 24.1).
      approvals?: opts[:approvals] == true,
      port: nil,
      os_pid: nil,
      # pi leads its own process group (pgid == os_pid). pi's bash tool starts each command in
      # a session of its own; bm_guard records those group ids in `pgid_file` (BM_PGID_FILE).
      # Every group is ended when pi exits or the agent stops (decision D18).
      pgid: nil,
      pgid_file: nil,
      # Groups seen empty once are never signalled again: their ids may be reused.
      dead_groups: MapSet.new(),
      pgid_dir: opts[:pgid_dir] || config[:pgid_dir] || Path.join(System.tmp_dir!(), "bm/pgids"),
      buffer: "",
      # Incremented every time the pi session is replaced (new process or confirmed new_session).
      session_epoch: 0,
      status: :starting,
      model: nil,
      tool: nil,
      usage: nil,
      spend: %{confirmed: 0.0, unknown: 0},
      transcript: [],
      tool_calls: ToolCalls.new(),
      next_id: 1,
      # request id => %{type: command type, from: caller waiting for the response or nil}
      pending: %{},
      # dialog id => request forwarded to the owner and not yet answered
      dialogs: %{}
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: {:noreply, open_port(state)}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{transcript: state.transcript, summary: summary(state)}, state}
  end

  def handle_call({:prompt, text}, from, state) do
    state = if state.port, do: state, else: open_port(state)

    if state.port do
      command =
        if state.status == :running,
          do: %{type: "prompt", message: text, streamingBehavior: "followUp"},
          else: %{type: "prompt", message: text}

      {:noreply, state |> emit({:user, text}) |> send_command(command, from)}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  def handle_call(:process_groups, _from, state) do
    {live, state} = live_groups(state)
    {:reply, live, state}
  end

  def handle_call(_command, _from, %{port: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call({:steer, text}, from, state) do
    {:noreply,
     state
     |> emit({:notice, "BM told the worker: #{text}"})
     |> send_command(%{type: "steer", message: text}, from)}
  end

  def handle_call({:follow_up, text}, from, state) do
    {:noreply,
     state |> emit({:user, text}) |> send_command(%{type: "follow_up", message: text}, from)}
  end

  def handle_call(:new_session, from, state),
    do: {:noreply, send_command(state, %{type: "new_session"}, from)}

  def handle_call(:abort, from, state),
    do: {:noreply, send_command(state, %{type: "abort"}, from)}

  @impl true
  def handle_cast({:respond, dialog_id, reply}, state) do
    case Map.pop(state.dialogs, dialog_id) do
      {nil, _} ->
        # Stale: the dialog belonged to an earlier session or was already answered.
        {:noreply, state}

      {%{op: "approval"} = request, dialogs} ->
        {:noreply, answer_approval(%{state | dialogs: dialogs}, request, reply)}

      {_request, dialogs} ->
        {:noreply, answer_dialog(%{state | dialogs: dialogs}, dialog_id, reply)}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, append_buffer(state, chunk)}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    case append_buffer(state, chunk) do
      %{buffer: :overflow} = state ->
        {:noreply, emit(%{state | buffer: ""}, {:error, "Dropped an oversized line from pi."})}

      state ->
        line = String.trim_trailing(state.buffer, "\r")
        {:noreply, handle_line(%{state | buffer: ""}, line)}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    for {_id, %{from: from}} <- state.pending, from, do: GenServer.reply(from, {:error, :exited})

    state = %{
      end_groups(state)
      | port: nil,
        os_pid: nil,
        buffer: "",
        status: :exited,
        tool: nil,
        pending: %{},
        dialogs: %{}
    }

    {:noreply,
     emit(state, {:error, "pi exited with status #{code}. Send a message to restart it."})}
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    state =
      Enum.reduce(state.dialogs, %{state | owner: nil, dialogs: %{}}, fn
        {_dialog_id, %{op: "approval"} = request}, acc ->
          answer_approval(acc, request, %{"cancelled" => true})

        {dialog_id, _request}, acc ->
          answer_dialog(acc, dialog_id, %{"ok" => false, "error" => "no_owner"})
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = state) when is_port(port) do
    # A killed pi can leave its auth-storage lock behind and delay the next start by up to
    # 30 s, so ask pi to exit by itself first; escalate only if it doesn't.
    graceful? =
      if state.shutdown_command do
        send_record(state, %{type: "prompt", message: state.shutdown_command})
        await_exit(port, 10_000)
      end

    stopped_by =
      cond do
        graceful? -> :shutdown_command
        kill_and_wait(state, "TERM", 3_000) -> :sigterm
        kill_and_wait(state, "KILL", 2_000) -> :sigkill
        true -> :unknown
      end

    Logger.info("pi agent #{state.id}: stopped by #{stopped_by}")
    end_groups(state)
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # Ends every process pi or its bash commands left behind, then forgets the groups.
  defp end_groups(%{pgid: nil} = state), do: state

  defp end_groups(state) do
    {groups, state} = live_groups(state)

    case Bm.Proc.terminate_groups(groups) do
      :ok ->
        File.rm(state.pgid_file)

      {:error, pids} ->
        Logger.error("pi agent #{state.id}: processes survived a group kill: #{inspect(pids)}")
    end

    %{state | pgid: nil, pgid_file: nil, dead_groups: MapSet.new()}
  end

  # pi's group and every group bm_guard recorded that still has processes; the empty ones are
  # remembered as dead so a later reuse of their ids is never signalled.
  defp live_groups(%{pgid: nil} = state), do: {[], state}

  defp live_groups(state) do
    known =
      [state.pgid | Bm.Proc.read_pgid_file(state.pgid_file)]
      |> Enum.reject(&MapSet.member?(state.dead_groups, &1))

    live = Bm.Proc.live_groups(known)
    dead = MapSet.union(state.dead_groups, MapSet.new(known -- live))
    {live, %{state | dead_groups: dead}}
  end

  defp new_pgid_file(state) do
    File.mkdir_p!(state.pgid_dir)
    name = String.replace(state.id, ~r/[^\w.-]/, "_")
    path = Path.join(state.pgid_dir, "#{name}-#{System.unique_integer([:positive])}.pgids")
    File.write!(path, "")
    path
  end

  defp kill_and_wait(%{os_pid: os_pid, port: port}, signal, timeout) do
    System.cmd("kill", ["-#{signal}", to_string(os_pid)], stderr_to_stdout: true)
    await_exit(port, timeout)
  end

  # Keeps reading pi's output (so pi never hits a closed pipe) until it exits.
  defp await_exit(port, timeout) do
    receive do
      {^port, {:exit_status, _}} -> true
      {^port, {:data, _}} -> await_exit(port, timeout)
    after
      timeout -> false
    end
  end

  defp open_port(state) do
    [executable | args] = state.command

    case System.find_executable(executable) do
      nil ->
        emit(
          %{state | status: :exited},
          {:error, "Cannot start pi: #{executable} not found in PATH."}
        )

      path ->
        pgid_file = new_pgid_file(state)
        env = Map.put(state.env, "BM_PGID_FILE", pgid_file)
        {launcher, launch_args} = Bm.Proc.launch_args(path, args)

        port =
          Port.open({:spawn_executable, launcher}, [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            {:line, @max_line_bytes},
            {:args, launch_args},
            {:cd, state.cwd},
            {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
          ])

        # The launcher execs pi, so this is pi's pid and its process group id.
        {:os_pid, os_pid} = Port.info(port, :os_pid)

        %{
          state
          | port: port,
            os_pid: os_pid,
            pgid: os_pid,
            pgid_file: pgid_file,
            status: :starting,
            session_epoch: state.session_epoch + 1,
            tool_calls: ToolCalls.new()
        }
        |> emit(:status)
        |> send_command(%{type: "get_state"}, nil)
    end
  end

  defp send_command(state, command, from) do
    id = "bm-#{state.next_id}"
    Port.command(state.port, [JSON.encode!(Map.put(command, :id, id)), "\n"])

    %{
      state
      | next_id: state.next_id + 1,
        pending: Map.put(state.pending, id, %{type: command.type, from: from})
    }
  end

  defp send_record(state, record) do
    Port.command(state.port, [JSON.encode!(record), "\n"])
    state
  end

  defp append_buffer(%{buffer: :overflow} = state, _chunk), do: state

  defp append_buffer(state, chunk) do
    if byte_size(state.buffer) + byte_size(chunk) > @max_buffer_bytes,
      do: %{state | buffer: :overflow},
      else: %{state | buffer: state.buffer <> chunk}
  end

  defp handle_line(state, ""), do: state

  defp handle_line(state, line) do
    state = log_raw(state, line)

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

  defp log_raw(%{raw_log: nil} = state, _line), do: state

  defp log_raw(state, line) do
    if state.raw_log_bytes + byte_size(line) > @max_raw_log_bytes do
      Logger.warning("pi agent #{state.id}: raw log limit reached, logging stopped")
      %{state | raw_log: nil}
    else
      File.write(state.raw_log, [line, "\n"], [:append])
      %{state | raw_log_bytes: state.raw_log_bytes + byte_size(line) + 1}
    end
  end

  defp handle_record(state, %{"type" => "response"} = response) do
    {entry, pending} = Map.pop(state.pending, response["id"])
    state = %{state | pending: pending}
    success? = response["success"] != false
    type = entry && entry.type

    if entry && entry.from do
      GenServer.reply(entry.from, if(success?, do: :ok, else: {:error, response["error"]}))
    end

    cond do
      not success? ->
        emit(state, {:error, "pi #{response["command"]} failed: #{response["error"]}"})

      type == "get_state" ->
        data = response["data"] || %{}
        status = if(data["isStreaming"], do: :running, else: :idle)
        emit(%{state | model: model_name(data["model"]), status: status}, :status)

      type == "new_session" ->
        # The session is replaced only once pi confirms it.
        state = %{
          state
          | session_epoch: state.session_epoch + 1,
            tool_calls: ToolCalls.new(),
            usage: nil
        }

        emit(state, :reset)

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
        {tool_calls, observed} = ToolCalls.apply(state.tool_calls, event)

        Enum.reduce(observed, %{state | tool_calls: tool_calls}, fn {stage, call}, acc ->
          emit(acc, {:tool_call, stage, call})
        end)

      _ ->
        state
    end
  end

  defp handle_record(state, %{
         "type" => "message_end",
         "message" => %{"role" => "assistant"} = message
       }) do
    state = add_spend(state, message["usage"])

    case message["stopReason"] do
      "error" -> emit(state, {:error, short_error(message["errorMessage"])})
      "aborted" -> emit(state, {:notice, "Stopped."})
      _ -> emit(state, :status)
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

  # Authoritative BM request: an input dialog titled "bm:<op>" carrying a JSON request.
  defp handle_record(
         state,
         %{
           "type" => "extension_ui_request",
           "method" => "input",
           "title" => "bm:" <> op,
           "id" => dialog_id
         } = request
       ) do
    with {:ok, %{"v" => 1, "request_id" => request_id} = body} when is_binary(request_id) <-
           JSON.decode(request["placeholder"] || ""),
         owner when is_pid(owner) <- state.owner do
      forwarded = %{
        dialog_id: dialog_id,
        op: op,
        request_id: request_id,
        payload: body["payload"] || %{},
        session_epoch: state.session_epoch
      }

      send(owner, {:pi_request, state.id, forwarded})
      %{state | dialogs: Map.put(state.dialogs, dialog_id, forwarded)}
    else
      nil -> answer_dialog(state, dialog_id, %{"ok" => false, "error" => "no_owner"})
      _ -> answer_dialog(state, dialog_id, %{"ok" => false, "error" => "malformed_request"})
    end
  end

  # The bm_* extensions report best-effort telemetry as `bm:`-prefixed notify records.
  defp handle_record(
         state,
         %{"type" => "extension_ui_request", "method" => "notify", "message" => "bm:" <> json}
       ) do
    case JSON.decode(json) do
      {:ok, %{"event" => event, "data" => data}} -> emit(state, {:bridge, event, data})
      _ -> state
    end
  end

  # Another extension asks the user (plan 24.1): in a worker's session the owner shows it on the
  # run page and sends the answer back through respond/3.
  defp handle_record(
         %{approvals?: true, owner: owner} = state,
         %{"type" => "extension_ui_request", "method" => method, "id" => dialog_id} = request
       )
       when method in @dialog_methods and is_pid(owner) do
    forwarded = %{
      dialog_id: dialog_id,
      op: "approval",
      request_id: dialog_id,
      payload: Map.take(request, ~w(method title message options placeholder prefill timeout)),
      session_epoch: state.session_epoch
    }

    send(owner, {:pi_request, state.id, forwarded})
    state = %{state | dialogs: Map.put(state.dialogs, dialog_id, forwarded)}
    emit(state, {:notice, "Waiting for your approval: #{request["title"] || method}"})
  end

  defp handle_record(state, %{"type" => "extension_ui_request", "method" => method} = request)
       when method in @dialog_methods do
    state
    |> send_record(%{type: "extension_ui_response", id: request["id"], cancelled: true})
    |> emit({:notice, "Declined pi dialog: #{request["title"] || method}"})
  end

  defp handle_record(state, %{"type" => "extension_error"} = record) do
    emit(state, {:notice, "pi extension error: #{record["error"]}"})
  end

  defp handle_record(state, _record), do: state

  defp answer_dialog(%{port: nil} = state, _dialog_id, _reply), do: state

  defp answer_dialog(state, dialog_id, reply) do
    send_record(state, %{
      type: "extension_ui_response",
      id: dialog_id,
      value: JSON.encode!(reply)
    })
  end

  # pi's own answer shapes: `confirmed` (confirm), `value` (select, input, editor), `cancelled`.
  defp answer_approval(%{port: nil} = state, _request, _reply), do: state

  defp answer_approval(state, request, reply) do
    fields =
      case Map.take(reply, ["confirmed", "value", "cancelled"]) do
        empty when empty == %{} -> %{"cancelled" => true}
        fields -> fields
      end

    question = request.payload["title"] || request.payload["method"]

    state
    |> send_record(
      Map.merge(%{"type" => "extension_ui_response", "id" => request.dialog_id}, fields)
    )
    |> emit({:notice, "Approval #{approval_outcome(fields)}: #{question}"})
  end

  defp approval_outcome(%{"cancelled" => true}), do: "declined"
  defp approval_outcome(%{"confirmed" => true}), do: "given (yes)"
  defp approval_outcome(%{"confirmed" => false}), do: "refused (no)"
  defp approval_outcome(%{"value" => value}), do: "answered #{inspect(value)}"
  defp approval_outcome(_fields), do: "answered"

  defp emit(state, event) do
    state = %{
      state
      | transcript: state.transcript |> Transcript.apply(event) |> Transcript.limit()
    }

    Bm.Pi.broadcast(state.id, event, summary(state))
    state
  end

  defp summary(state) do
    %{
      status: state.status,
      model: state.model,
      tool: state.tool,
      usage: state.usage,
      spend: state.spend,
      session_epoch: state.session_epoch,
      cwd: state.cwd,
      pgid: state.pgid,
      pgid_file: state.pgid_file
    }
  end

  # Confirmed spend comes from each finished assistant message; a message without a cost is
  # counted as unknown, never as zero.
  defp add_spend(state, %{"cost" => %{"total" => total}}) when is_number(total),
    do: put_in(state.spend.confirmed, state.spend.confirmed + total)

  defp add_spend(state, _usage), do: put_in(state.spend.unknown, state.spend.unknown + 1)

  # Provider errors can carry request details and a stack trace; keep the readable part.
  defp short_error(message) when is_binary(message) and message != "" do
    message |> String.split("; details=") |> hd() |> String.split("\n") |> hd()
  end

  defp short_error(_message), do: "The model request failed."

  defp model_name(%{"name" => name}), do: name
  defp model_name(%{"id" => id}), do: id
  defp model_name(_), do: nil

  # Values pi didn't report stay nil (unknown) rather than 0.
  defp usage_summary(usage) do
    %{
      input: usage["input"],
      output: usage["output"],
      cache_read: usage["cacheRead"],
      cost: get_in(usage, ["cost", "total"])
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
