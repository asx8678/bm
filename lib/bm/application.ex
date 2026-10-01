defmodule Bm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BmWeb.Telemetry,
      Bm.Repo,
      {DNSCluster, query: Application.get_env(:bm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bm.PubSub},
      # pi agents: one Bm.Pi.Agent per agent id, found through the registry
      {Registry, keys: :unique, name: Bm.Pi.Registry},
      {DynamicSupervisor, name: Bm.Pi.AgentSupervisor, strategy: :one_for_one},
      # Workspace coordinators: one per checkout, found by canonical path
      {Registry, keys: :unique, name: Bm.Workspace.Registry},
      {DynamicSupervisor, name: Bm.Workspace.Supervisor, strategy: :one_for_one},
      # Blocking work of coordinators (starting/stopping pi, verification)
      {Task.Supervisor, name: Bm.TaskSupervisor},
      Bm.Chat,
      # Attempts left in flight by the previous run of the app (docs/ARCHITECTURE.md §11)
      recovery(),
      # Start to serve requests, typically the last entry
      BmWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp recovery do
    if Application.get_env(:bm, :recover_on_start, true),
      do: {Task, &Bm.Workspace.Recovery.run/0},
      else: {Task, fn -> :ok end}
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
