defmodule Wail.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WailWeb.Telemetry,
      Wail.Repo,
      {DNSCluster, query: Application.get_env(:wail, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Wail.PubSub},
      {Registry, keys: :unique, name: Wail.Classrooms.Registry},
      Wail.Classrooms.Supervisor,
      WailWeb.ClassroomPresence,
      # Start to serve requests, typically the last entry
      WailWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Wail.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WailWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
