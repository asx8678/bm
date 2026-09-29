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

  @doc "Sends a user prompt. While the agent is working, it is queued as a follow-up."
  def prompt(id, text), do: GenServer.call(via(id), {:prompt, text})

  @doc "Aborts the agent's current run."
  def abort(id), do: GenServer.call(via(id), :abort)

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
