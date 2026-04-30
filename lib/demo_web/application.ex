defmodule DemoWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Attach bc_gitops telemetry handlers before starting supervision tree
    DemoWeb.GitopsTelemetry.attach()

    # Start macula clustering if configured
    # Uses gossip strategy for zero-config LAN discovery by default
    start_macula_cluster()

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

  # Start macula_cluster with the configured strategy
  defp start_macula_cluster do
    strategy = Application.get_env(:demo_web, :cluster_strategy, :gossip)
    nodes = Application.get_env(:demo_web, :cluster_nodes, [])

    opts =
      case {strategy, nodes} do
        {:static, nodes} when nodes != [] ->
          # Static strategy with explicit node list
          %{strategy: :static, nodes: nodes}

        {:gossip, _} ->
          # Gossip strategy for zero-config LAN discovery
          secret = Application.get_env(:demo_web, :cluster_secret)
          base_opts = %{strategy: :gossip}

          if secret do
            Map.put(base_opts, :secret, secret)
          else
            base_opts
          end

        _ ->
          # Default to gossip if no nodes configured
          %{strategy: :gossip}
      end

    case :macula_cluster.start_cluster(opts) do
      :ok ->
        Logger.info("[DemoWeb] Started macula_cluster with strategy: #{strategy}")

      {:error, reason} ->
        Logger.warning("[DemoWeb] Failed to start macula_cluster: #{inspect(reason)}")
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DemoWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
