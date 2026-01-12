defmodule DemoWeb.GitopsTelemetry do
  @moduledoc """
  Bridges bc_gitops telemetry events to Phoenix PubSub for real-time dashboard updates.
  """

  require Logger

  @doc """
  Attach telemetry handlers for bc_gitops events.
  """
  def attach do
    events = [
      [:bc_gitops, :reconcile, :start],
      [:bc_gitops, :reconcile, :stop],
      [:bc_gitops, :reconcile, :error],
      [:bc_gitops, :deploy, :start],
      [:bc_gitops, :deploy, :stop],
      [:bc_gitops, :upgrade, :start],
      [:bc_gitops, :upgrade, :stop],
      [:bc_gitops, :remove, :start],
      [:bc_gitops, :remove, :stop],
      [:bc_gitops, :git, :pull]
    ]

    :telemetry.attach_many(
      "demo-web-gitops-telemetry",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Handle telemetry events from bc_gitops.
  """
  def handle_event(event, measurements, metadata, _config) do
    # Log the event
    Logger.info("[GitOps] #{inspect(event)} - #{inspect(metadata)}")

    # Broadcast to PubSub for LiveView updates
    Phoenix.PubSub.broadcast(
      DemoWeb.PubSub,
      "gitops:events",
      {:gitops_event, event, measurements, metadata}
    )
  end
end
