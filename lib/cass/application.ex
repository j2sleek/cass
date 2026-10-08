defmodule Cass.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:cass, :started_monotonic, System.monotonic_time())

    # Start to serve requests, typically the last entry
    children =
      [
        CassWeb.Telemetry,
        Cass.Repo,
        {DNSCluster, query: Application.get_env(:cass, :dns_cluster_query) || :ignore},
        {Oban, Application.fetch_env!(:cass, Oban)},
        {Phoenix.PubSub, name: Cass.PubSub}
      ] ++
        analytics_children() ++
        [CassWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cass.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The buffered analytics writer is enabled everywhere except the test suite,
  # where events are written synchronously inside the Ecto sandbox. See
  # `Cass.Analytics` and `config/test.exs`.
  defp analytics_children do
    if Application.get_env(:cass, Cass.Analytics, [])[:writer] == false do
      []
    else
      [Cass.Analytics.Writer]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CassWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
