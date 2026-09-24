defmodule Cass.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:cass, :started_monotonic, System.monotonic_time())

    children = [
      CassWeb.Telemetry,
      Cass.Repo,
      {DNSCluster, query: Application.get_env(:cass, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cass.PubSub},
      # Start a worker by calling: Cass.Worker.start_link(arg)
      # {Cass.Worker, arg},
      # Start to serve requests, typically the last entry
      CassWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cass.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CassWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
