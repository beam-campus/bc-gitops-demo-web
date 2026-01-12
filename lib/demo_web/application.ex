defmodule DemoWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach bc_gitops telemetry handlers before starting supervision tree
    DemoWeb.GitopsTelemetry.attach()

    children = [
      DemoWebWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:demo_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DemoWeb.PubSub},
      # Start to serve requests, typically the last entry
      DemoWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DemoWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DemoWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
