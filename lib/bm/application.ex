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
      # Start a worker by calling: Bm.Worker.start_link(arg)
      # {Bm.Worker, arg},
      # Start to serve requests, typically the last entry
      BmWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
