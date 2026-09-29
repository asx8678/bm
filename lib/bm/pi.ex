defmodule Bm.Pi do
  @moduledoc """
  Runs pi coding agents as supervised processes and talks to them over pi's RPC mode.

  Each agent is a `Bm.Pi.Agent` under `Bm.Pi.AgentSupervisor`, registered by id in
  `Bm.Pi.Registry`. Subscribers of `subscribe/1` receive
  `{:pi, agent_id, event, summary}`, where `event` is applied with
  `Bm.Pi.Transcript.apply/2` and `summary` describes the agent (status, model,
  current tool, token usage).
  """

  alias Bm.Pi.Agent

  @doc "Starts the agent `id` unless it is already running."
  def ensure_agent(id, opts \\ []) do
    case DynamicSupervisor.start_child(Bm.Pi.AgentSupervisor, {Agent, Keyword.put(opts, :id, id)}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  # Commands wait for pi's correlated response; abort waits until pi is idle again.
  @command_timeout 30_000
  @abort_timeout 120_000

  @doc """
  Sends a user prompt; `:ok` once pi accepted it. While the agent is working, the prompt is
  queued as a follow-up.
  """
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text}, @command_timeout)

  @doc "Queues a message for delivery after the agent finishes its current work."
  def follow_up(id, text), do: GenServer.call(via(id), {:follow_up, text}, @command_timeout)

  @doc "Replaces the pi session; `:ok` only after pi confirmed it."
  def new_session(id), do: GenServer.call(via(id), :new_session, @command_timeout)

  @doc "Aborts the agent's current run; returns once pi is idle."
  def abort(id), do: GenServer.call(via(id), :abort, @abort_timeout)

  @doc """
  Answers an authoritative request forwarded to the agent's owner as
  `{:pi_request, agent_id, %{dialog_id: ...}}`. `reply` is JSON-encodable and should carry
  `"ok"`. Answers to unknown or stale dialogs are ignored.
  """
  def respond(id, dialog_id, reply), do: GenServer.cast(via(id), {:respond, dialog_id, reply})

  @doc "OS pid of the agent's current pi process, or nil."
  def os_pid(id), do: GenServer.call(via(id), :os_pid)

  @doc "Returns `%{transcript: entries, summary: summary}` for the agent."
  def snapshot(id), do: GenServer.call(via(id), :snapshot)

  @doc "Stops the agent and its pi process."
  def stop(id) do
    case Registry.lookup(Bm.Pi.Registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Bm.Pi.AgentSupervisor, pid)
      [] -> :ok
    end
  end

  def subscribe(id), do: Phoenix.PubSub.subscribe(Bm.PubSub, topic(id))

  @doc false
  def broadcast(id, event, summary) do
    Phoenix.PubSub.broadcast(Bm.PubSub, topic(id), {:pi, id, event, summary})
  end

  @doc false
  def via(id), do: {:via, Registry, {Bm.Pi.Registry, id}}

  defp topic(id), do: "pi_agent:#{id}"
end
