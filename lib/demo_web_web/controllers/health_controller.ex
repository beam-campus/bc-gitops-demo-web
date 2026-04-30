defmodule DemoWebWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestration.

  Returns JSON with node info and cluster status.
  """
  use DemoWebWeb, :controller

  def index(conn, _params) do
    health_info = %{
      status: "ok",
      node: Node.self(),
      cluster_nodes: Node.list(),
      uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    }

    json(conn, health_info)
  end
end
