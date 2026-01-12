defmodule DemoWebWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for bc_gitops - shows managed applications and real-time events.
  """
  use DemoWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to bc_gitops telemetry events
      Phoenix.PubSub.subscribe(DemoWeb.PubSub, "gitops:events")
      # Refresh status periodically
      :timer.send_interval(5000, self(), :refresh_status)
    end

    socket =
      socket
      |> assign(:status, fetch_status())
      |> assign(:apps, fetch_apps())
      |> assign(:events, [])
      |> assign(:syncing, false)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_status, socket) do
    socket =
      socket
      |> assign(:status, fetch_status())
      |> assign(:apps, fetch_apps())

    {:noreply, socket}
  end

  @impl true
  def handle_info({:gitops_event, event, measurements, metadata}, socket) do
    # Add event to the list (keep last 20)
    event_entry = %{
      event: event,
      measurements: measurements,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    events = [event_entry | socket.assigns.events] |> Enum.take(20)

    # Update syncing state
    syncing =
      case event do
        [:bc_gitops, :reconcile, :start] -> true
        [:bc_gitops, :reconcile, :stop] -> false
        [:bc_gitops, :reconcile, :error] -> false
        _ -> socket.assigns.syncing
      end

    socket =
      socket
      |> assign(:events, events)
      |> assign(:syncing, syncing)
      |> assign(:status, fetch_status())
      |> assign(:apps, fetch_apps())

    {:noreply, socket}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    # Trigger manual reconciliation
    spawn(fn -> :bc_gitops.reconcile() end)
    {:noreply, assign(socket, :syncing, true)}
  end

  defp fetch_status do
    case :bc_gitops.status() do
      {:ok, status} -> status
      _ -> %{status: :unknown, last_commit: nil, app_count: 0, healthy_count: 0}
    end
  end

  defp fetch_apps do
    case :bc_gitops.get_current_state() do
      {:ok, apps} when is_map(apps) ->
        # Convert Erlang records to maps
        Map.new(apps, fn {name, app} -> {name, record_to_map(app)} end)
      _ ->
        %{}
    end
  end

  # Convert Erlang #app_state{} record to a map
  # Record format: {:app_state, name, version, status, path, pid, started_at, health, env}
  defp record_to_map({:app_state, name, version, status, path, pid, started_at, health, env}) do
    %{
      name: name,
      version: version,
      status: status,
      path: path,
      pid: pid,
      started_at: started_at,
      health: health,
      env: env
    }
  end

  defp record_to_map(other) when is_map(other), do: other
  defp record_to_map(_), do: %{}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-gray-100">
      <header class="bg-gray-800 shadow-lg border-b border-gray-700">
        <div class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
          <div class="flex justify-between items-center">
            <div>
              <h1 class="text-3xl font-bold text-white">bc_gitops Dashboard</h1>
              <p class="text-gray-400 mt-1">GitOps for the BEAM</p>
            </div>
            <button
              phx-click="sync"
              disabled={@syncing}
              class={"px-4 py-2 rounded-lg font-medium transition-colors " <>
                if @syncing do
                  "bg-gray-600 text-gray-400 cursor-not-allowed"
                else
                  "bg-blue-600 hover:bg-blue-700 text-white"
                end}
            >
              <%= if @syncing do %>
                <span class="flex items-center gap-2">
                  <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
                  </svg>
                  Syncing...
                </span>
              <% else %>
                Sync Now
              <% end %>
            </button>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
        <!-- Status Bar -->
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
          <.status_card
            title="Status"
            value={status_text(@status.status)}
            color={status_color(@status.status)}
          />
          <.status_card
            title="Last Commit"
            value={truncate_commit(@status[:last_commit])}
            color="gray"
          />
          <.status_card
            title="Apps"
            value={"#{@status[:app_count] || 0}"}
            color="blue"
          />
          <.status_card
            title="Healthy"
            value={"#{@status[:healthy_count] || 0}"}
            color="green"
          />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
          <!-- Managed Apps -->
          <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
            <div class="px-6 py-4 border-b border-gray-700">
              <h2 class="text-xl font-semibold text-white">Managed Applications</h2>
            </div>
            <div class="p-6">
              <%= if map_size(@apps) == 0 do %>
                <div class="text-center py-8 text-gray-500">
                  <svg class="mx-auto h-12 w-12 text-gray-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4"/>
                  </svg>
                  <p class="mt-2">No applications deployed yet</p>
                  <p class="text-sm text-gray-600">Add an app.config to your GitOps repo</p>
                </div>
              <% else %>
                <div class="space-y-4">
                  <%= for {name, app} <- @apps do %>
                    <.app_card name={name} app={app} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Event Log -->
          <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
            <div class="px-6 py-4 border-b border-gray-700">
              <h2 class="text-xl font-semibold text-white">Event Log</h2>
            </div>
            <div class="p-6 max-h-96 overflow-y-auto">
              <%= if @events == [] do %>
                <div class="text-center py-8 text-gray-500">
                  <p>Waiting for events...</p>
                </div>
              <% else %>
                <div class="space-y-2">
                  <%= for event <- @events do %>
                    <.event_entry event={event} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # Components

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :color, :string, default: "gray"

  defp status_card(assigns) do
    ~H"""
    <div class={"bg-gray-800 rounded-lg p-4 border border-gray-700"}>
      <p class="text-sm text-gray-400"><%= @title %></p>
      <p class={"text-2xl font-bold " <> color_class(@color)}><%= @value %></p>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :app, :map, required: true

  defp app_card(assigns) do
    ~H"""
    <div class="bg-gray-700 rounded-lg p-4 border border-gray-600">
      <div class="flex justify-between items-start">
        <div>
          <h3 class="font-semibold text-white"><%= @name %></h3>
          <p class="text-sm text-gray-400">v<%= get_in(@app, [:version]) || "?" %></p>
        </div>
        <span class={
          "px-2 py-1 text-xs font-medium rounded-full " <>
          case get_in(@app, [:status]) do
            :running -> "bg-green-900 text-green-300"
            :stopped -> "bg-gray-600 text-gray-300"
            :failed -> "bg-red-900 text-red-300"
            _ -> "bg-gray-600 text-gray-300"
          end
        }>
          <%= get_in(@app, [:status]) || :unknown %>
        </span>
      </div>
      <div class="mt-2 text-xs text-gray-500">
        Health: <%= get_in(@app, [:health]) || :unknown %>
      </div>
    </div>
    """
  end

  attr :event, :map, required: true

  defp event_entry(assigns) do
    ~H"""
    <div class="text-sm border-l-2 border-gray-600 pl-3 py-1">
      <div class="flex justify-between">
        <span class={"font-medium " <> event_color(@event.event)}>
          <%= event_name(@event.event) %>
        </span>
        <span class="text-gray-500 text-xs">
          <%= Calendar.strftime(@event.timestamp, "%H:%M:%S") %>
        </span>
      </div>
      <%= if @event.metadata[:app] do %>
        <p class="text-gray-400 text-xs">App: <%= @event.metadata[:app] %></p>
      <% end %>
    </div>
    """
  end

  # Helpers

  defp status_text(:synced), do: "Synced"
  defp status_text(:out_of_sync), do: "Out of Sync"
  defp status_text(:error), do: "Error"
  defp status_text(_), do: "Unknown"

  defp status_color(:synced), do: "green"
  defp status_color(:out_of_sync), do: "yellow"
  defp status_color(:error), do: "red"
  defp status_color(_), do: "gray"

  defp color_class("green"), do: "text-green-400"
  defp color_class("yellow"), do: "text-yellow-400"
  defp color_class("red"), do: "text-red-400"
  defp color_class("blue"), do: "text-blue-400"
  defp color_class(_), do: "text-gray-300"

  defp truncate_commit(nil), do: "-"
  defp truncate_commit(commit) when is_binary(commit), do: String.slice(commit, 0, 7)
  defp truncate_commit(_), do: "-"

  defp event_name([:bc_gitops, :reconcile, :start]), do: "Reconcile started"
  defp event_name([:bc_gitops, :reconcile, :stop]), do: "Reconcile complete"
  defp event_name([:bc_gitops, :reconcile, :error]), do: "Reconcile error"
  defp event_name([:bc_gitops, :deploy, :start]), do: "Deploy started"
  defp event_name([:bc_gitops, :deploy, :stop]), do: "Deploy complete"
  defp event_name([:bc_gitops, :upgrade, :start]), do: "Upgrade started"
  defp event_name([:bc_gitops, :upgrade, :stop]), do: "Upgrade complete"
  defp event_name([:bc_gitops, :remove, :start]), do: "Remove started"
  defp event_name([:bc_gitops, :remove, :stop]), do: "Remove complete"
  defp event_name([:bc_gitops, :git, :pull]), do: "Git pull"
  defp event_name(event), do: inspect(event)

  defp event_color([:bc_gitops, :reconcile, :start]), do: "text-blue-400"
  defp event_color([:bc_gitops, :reconcile, :stop]), do: "text-green-400"
  defp event_color([:bc_gitops, :reconcile, :error]), do: "text-red-400"
  defp event_color([:bc_gitops, :deploy, _]), do: "text-purple-400"
  defp event_color([:bc_gitops, :upgrade, _]), do: "text-yellow-400"
  defp event_color([:bc_gitops, :remove, _]), do: "text-orange-400"
  defp event_color(_), do: "text-gray-400"
end
