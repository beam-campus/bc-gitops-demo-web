defmodule DemoWebWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for bc_gitops - shows managed applications and real-time events.
  """
  use DemoWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DemoWeb.PubSub, "gitops:events")
      :timer.send_interval(5000, self(), :refresh_status)
    end

    socket =
      socket
      |> assign(:status, fetch_status())
      |> assign(:apps, fetch_apps())
      |> assign(:events, [])
      |> assign(:syncing, false)
      |> assign(:expanded_apps, MapSet.new())
      |> assign(:selected_app, nil)
      |> assign(:app_data, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"app" => app_name}, _uri, socket) do
    app_atom = String.to_existing_atom(app_name)
    app = socket.assigns.apps[app_atom]

    socket =
      socket
      |> assign(:selected_app, app_atom)
      |> maybe_fetch_app_data(app_atom, app)

    {:noreply, socket}
  rescue
    ArgumentError -> {:noreply, assign(socket, :selected_app, nil)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_app, nil)}
  end

  defp maybe_fetch_app_data(socket, app_name, app) when is_map(app) do
    case get_http_url(app) do
      nil -> socket
      base_url ->
        data = fetch_app_api_data(base_url)
        assign(socket, :app_data, Map.put(socket.assigns.app_data, app_name, data))
    end
  end

  defp maybe_fetch_app_data(socket, _app_name, _app), do: socket

  defp fetch_app_api_data(base_url) do
    case :httpc.request(:get, {~c"#{base_url}/health", []}, [{:timeout, 2000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, data} -> data
          _ -> %{"error" => "Invalid JSON"}
        end
      {:error, reason} ->
        %{"error" => inspect(reason)}
      _ ->
        %{"error" => "Request failed"}
    end
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
    event_entry = %{
      id: System.unique_integer([:positive]),
      event: event,
      measurements: measurements,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    events = [event_entry | socket.assigns.events] |> Enum.take(50)

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
    spawn(fn -> :bc_gitops.reconcile() end)
    {:noreply, assign(socket, :syncing, true)}
  end

  def handle_event("toggle_app", %{"app" => app_name}, socket) do
    app_atom = String.to_existing_atom(app_name)
    expanded = socket.assigns.expanded_apps

    expanded =
      if MapSet.member?(expanded, app_atom) do
        MapSet.delete(expanded, app_atom)
      else
        MapSet.put(expanded, app_atom)
      end

    {:noreply, assign(socket, :expanded_apps, expanded)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("select_app", %{"app" => app_name}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?app=#{app_name}")}
  end

  def handle_event("close_app", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/")}
  end

  def handle_event("app_action", %{"app" => app_name, "action" => action}, socket) do
    app_atom = String.to_existing_atom(app_name)
    app = socket.assigns.apps[app_atom]

    case {action, get_http_url(app)} do
      {_, nil} ->
        {:noreply, socket}

      {"increment", base_url} ->
        post_app_action(base_url, "/increment")
        {:noreply, refresh_app_data(socket, app_atom, app)}

      {"reset", base_url} ->
        post_app_action(base_url, "/reset")
        {:noreply, refresh_app_data(socket, app_atom, app)}

      {"refresh", _base_url} ->
        {:noreply, refresh_app_data(socket, app_atom, app)}

      _ ->
        {:noreply, socket}
    end
  rescue
    ArgumentError -> {:noreply, socket}
  end

  defp post_app_action(base_url, path) do
    :httpc.request(:post, {~c"#{base_url}#{path}", [], ~c"application/json", ""}, [{:timeout, 2000}], [])
  end

  defp refresh_app_data(socket, app_name, app) do
    case get_http_url(app) do
      nil -> socket
      base_url ->
        data = fetch_app_api_data(base_url)
        assign(socket, :app_data, Map.put(socket.assigns.app_data, app_name, data))
    end
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
        Map.new(apps, fn {name, app} -> {name, record_to_map(app)} end)
      _ ->
        %{}
    end
  end

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
          <.status_card title="Status" value={status_text(@status.status)} color={status_color(@status.status)} />
          <.status_card title="Last Commit" value={truncate_commit(@status[:last_commit])} color="gray" />
          <.status_card title="Apps" value={"#{@status[:app_count] || 0}"} color="blue" />
          <.status_card title="Healthy" value={"#{@status[:healthy_count] || 0}"} color="green" />
        </div>

        <%= if @selected_app do %>
          <!-- App Detail View with Native Integration -->
          <.app_detail_panel app={@apps[@selected_app]} name={@selected_app} app_data={@app_data[@selected_app]} />
        <% else %>
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
                      <.app_card name={name} app={app} expanded={MapSet.member?(@expanded_apps, name)} />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Event Log -->
            <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
              <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
                <h2 class="text-xl font-semibold text-white">Event Log</h2>
                <span class="text-xs text-gray-500"><%= length(@events) %> events</span>
              </div>
              <div class="p-6 max-h-[600px] overflow-y-auto">
                <%= if @events == [] do %>
                  <div class="text-center py-8 text-gray-500">
                    <p>Waiting for events...</p>
                  </div>
                <% else %>
                  <div class="space-y-3">
                    <%= for event <- @events do %>
                      <.event_entry event={event} />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
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
    <div class="bg-gray-800 rounded-lg p-4 border border-gray-700">
      <p class="text-sm text-gray-400"><%= @title %></p>
      <p class={"text-2xl font-bold " <> color_class(@color)}><%= @value %></p>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :app, :map, required: true
  attr :expanded, :boolean, default: false

  defp app_card(assigns) do
    ~H"""
    <div class="bg-gray-700 rounded-lg border border-gray-600 overflow-hidden">
      <!-- Header - clickable to expand -->
      <div
        class="p-4 cursor-pointer hover:bg-gray-650 transition-colors"
        phx-click="toggle_app"
        phx-value-app={@name}
      >
        <div class="flex justify-between items-start">
          <div class="flex items-center gap-2">
            <svg class={"w-4 h-4 transition-transform " <> if(@expanded, do: "rotate-90", else: "")} fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd"/>
            </svg>
            <div>
              <h3 class="font-semibold text-white"><%= @name %></h3>
              <p class="text-sm text-gray-400">v<%= get_in(@app, [:version]) || "?" %></p>
            </div>
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
      </div>

      <!-- Expanded Details -->
      <%= if @expanded do %>
        <div class="border-t border-gray-600 p-4 bg-gray-750 space-y-3">
          <!-- Environment -->
          <div>
            <p class="text-xs text-gray-500 uppercase tracking-wide mb-1">Environment</p>
            <div class="font-mono text-sm bg-gray-800 rounded p-2 overflow-x-auto">
              <%= if is_map(@app[:env]) and map_size(@app[:env]) > 0 do %>
                <%= for {key, val} <- @app[:env] do %>
                  <div class="flex gap-2">
                    <span class="text-purple-400"><%= key %>:</span>
                    <span class="text-gray-300"><%= inspect(val) %></span>
                  </div>
                <% end %>
              <% else %>
                <span class="text-gray-500">No env configured</span>
              <% end %>
            </div>
          </div>

          <!-- Health & Started -->
          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p class="text-xs text-gray-500 uppercase tracking-wide">Health</p>
              <p class={"font-medium " <> health_color(@app[:health])}><%= @app[:health] || :unknown %></p>
            </div>
            <div>
              <p class="text-xs text-gray-500 uppercase tracking-wide">Started</p>
              <p class="text-gray-300"><%= format_started_at(@app[:started_at]) %></p>
            </div>
          </div>

          <!-- Path -->
          <div>
            <p class="text-xs text-gray-500 uppercase tracking-wide mb-1">Path</p>
            <p class="font-mono text-xs text-gray-400 truncate"><%= @app[:path] %></p>
          </div>

          <!-- Actions -->
          <div class="flex gap-2 pt-2">
            <%= if has_http_endpoint?(@app) do %>
              <button
                phx-click="select_app"
                phx-value-app={@name}
                class="px-3 py-1.5 bg-blue-600 hover:bg-blue-700 text-white text-sm rounded transition-colors"
              >
                Open UI
              </button>
              <a
                href={get_http_url(@app)}
                target="_blank"
                class="px-3 py-1.5 bg-gray-600 hover:bg-gray-500 text-white text-sm rounded transition-colors inline-flex items-center gap-1"
              >
                External
                <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/>
                </svg>
              </a>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :app, :map, required: true
  attr :name, :atom, required: true
  attr :app_data, :map, default: nil

  defp app_detail_panel(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
      <!-- Header -->
      <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
        <div class="flex items-center gap-3">
          <button
            phx-click="close_app"
            class="p-1 hover:bg-gray-700 rounded transition-colors"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
            </svg>
          </button>
          <div>
            <h2 class="text-xl font-semibold text-white"><%= @name %></h2>
            <p class="text-sm text-gray-400">v<%= @app[:version] || "?" %></p>
          </div>
        </div>
        <div class="flex items-center gap-3">
          <%= if has_http_endpoint?(@app) do %>
            <a
              href={get_http_url(@app)}
              target="_blank"
              class="text-sm text-blue-400 hover:text-blue-300 inline-flex items-center gap-1"
            >
              <%= get_http_url(@app) %>
              <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/>
              </svg>
            </a>
          <% end %>
          <span class={
            "px-3 py-1 text-sm font-medium rounded-full " <>
            case @app[:status] do
              :running -> "bg-green-900 text-green-300"
              :stopped -> "bg-gray-600 text-gray-300"
              :failed -> "bg-red-900 text-red-300"
              _ -> "bg-gray-600 text-gray-300"
            end
          }>
            <%= @app[:status] || :unknown %>
          </span>
        </div>
      </div>

      <!-- Native App UI Integration -->
      <%= if has_http_endpoint?(@app) do %>
        <.app_native_ui name={@name} app={@app} data={@app_data} />
      <% else %>
        <div class="p-6 text-center text-gray-500">
          <svg class="mx-auto h-12 w-12 text-gray-600 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
          </svg>
          <p>No HTTP endpoint configured for this application</p>
          <p class="text-sm mt-1">Add <code class="bg-gray-700 px-1 rounded">http_port</code> to env to enable embedding</p>
        </div>
      <% end %>

      <!-- App Details -->
      <div class="border-t border-gray-700 p-6 grid grid-cols-2 md:grid-cols-4 gap-4">
        <div>
          <p class="text-xs text-gray-500 uppercase tracking-wide">Health</p>
          <p class={"font-medium " <> health_color(@app[:health])}><%= @app[:health] || :unknown %></p>
        </div>
        <div>
          <p class="text-xs text-gray-500 uppercase tracking-wide">Started</p>
          <p class="text-gray-300"><%= format_started_at(@app[:started_at]) %></p>
        </div>
        <div class="col-span-2">
          <p class="text-xs text-gray-500 uppercase tracking-wide">Path</p>
          <p class="font-mono text-xs text-gray-400 truncate"><%= @app[:path] %></p>
        </div>
      </div>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :app, :map, required: true
  attr :data, :map, default: nil

  defp app_native_ui(assigns) do
    ~H"""
    <div class="p-6">
      <%= cond do %>
        <% @data == nil -> %>
          <!-- Loading state -->
          <div class="flex justify-center py-8">
            <svg class="animate-spin h-8 w-8 text-blue-400" viewBox="0 0 24 24">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
            </svg>
          </div>

        <% @data["error"] -> %>
          <!-- Error state -->
          <div class="bg-red-900/20 border border-red-700 rounded-lg p-4 text-center">
            <svg class="mx-auto h-8 w-8 text-red-400 mb-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
            </svg>
            <p class="text-red-400 font-medium">Connection Error</p>
            <p class="text-red-300 text-sm mt-1"><%= @data["error"] %></p>
            <button
              phx-click="app_action"
              phx-value-app={@name}
              phx-value-action="refresh"
              class="mt-3 px-4 py-2 bg-red-700 hover:bg-red-600 text-white rounded transition-colors"
            >
              Retry
            </button>
          </div>

        <% @name == :demo_counter -> %>
          <!-- Demo Counter specific UI -->
          <.counter_ui name={@name} data={@data} />

        <% true -> %>
          <!-- Generic app data display -->
          <.generic_app_ui name={@name} data={@data} />
      <% end %>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :data, :map, required: true

  defp counter_ui(assigns) do
    ~H"""
    <div class="flex flex-col items-center py-8">
      <!-- Counter Display -->
      <div class="bg-gradient-to-br from-gray-700 to-gray-800 rounded-2xl p-8 shadow-xl border border-gray-600 mb-8">
        <p class="text-gray-400 text-sm uppercase tracking-wider text-center mb-2">Current Count</p>
        <p class="text-7xl font-bold text-white text-center tabular-nums">
          <%= @data["count"] || 0 %>
        </p>
      </div>

      <!-- Status -->
      <div class="flex items-center gap-2 mb-6">
        <span class={"w-2 h-2 rounded-full " <> if(@data["status"] == "healthy", do: "bg-green-400 animate-pulse", else: "bg-red-400")} />
        <span class="text-sm text-gray-400">
          <%= if @data["status"] == "healthy", do: "Healthy", else: "Unhealthy" %>
        </span>
      </div>

      <!-- Action Buttons -->
      <div class="flex gap-4">
        <button
          phx-click="app_action"
          phx-value-app={@name}
          phx-value-action="increment"
          class="px-6 py-3 bg-blue-600 hover:bg-blue-500 text-white font-medium rounded-lg transition-colors flex items-center gap-2 shadow-lg"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 6v6m0 0v6m0-6h6m-6 0H6"/>
          </svg>
          Increment
        </button>

        <button
          phx-click="app_action"
          phx-value-app={@name}
          phx-value-action="reset"
          class="px-6 py-3 bg-gray-600 hover:bg-gray-500 text-white font-medium rounded-lg transition-colors flex items-center gap-2"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
          </svg>
          Reset
        </button>

        <button
          phx-click="app_action"
          phx-value-app={@name}
          phx-value-action="refresh"
          class="px-4 py-3 bg-gray-700 hover:bg-gray-600 text-white rounded-lg transition-colors"
          title="Refresh"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
          </svg>
        </button>
      </div>

      <!-- API Info -->
      <div class="mt-8 text-center text-sm text-gray-500">
        <p>This UI is integrated via HTTP API calls to the managed application</p>
        <p class="font-mono text-xs mt-1 text-gray-600">
          GET /count &bull; POST /increment &bull; POST /reset &bull; GET /health
        </p>
      </div>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :data, :map, required: true

  defp generic_app_ui(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between items-center mb-4">
        <h3 class="text-lg font-medium text-white">API Response</h3>
        <button
          phx-click="app_action"
          phx-value-app={@name}
          phx-value-action="refresh"
          class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition-colors flex items-center gap-1"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
          </svg>
          Refresh
        </button>
      </div>
      <pre class="bg-gray-900 rounded-lg p-4 overflow-x-auto text-sm font-mono text-gray-300"><%= Jason.encode!(@data, pretty: true) %></pre>
    </div>
    """
  end

  attr :event, :map, required: true

  defp event_entry(assigns) do
    ~H"""
    <div class={"text-sm border-l-2 pl-3 py-2 rounded-r " <> event_border_color(@event.event) <> " " <> event_bg_color(@event.event)}>
      <div class="flex justify-between items-start">
        <span class={"font-medium " <> event_text_color(@event.event)}>
          <%= event_name(@event.event) %>
        </span>
        <span class="text-gray-500 text-xs">
          <%= Calendar.strftime(@event.timestamp, "%H:%M:%S") %>
        </span>
      </div>

      <!-- App name if present -->
      <%= if @event.metadata[:app] do %>
        <p class="text-gray-400 text-xs mt-1">
          App: <span class="font-medium text-gray-300"><%= @event.metadata[:app] %></span>
        </p>
      <% end %>

      <!-- Duration for stop events -->
      <%= if @event.measurements[:duration] do %>
        <p class="text-gray-500 text-xs">
          Duration: <%= format_duration(@event.measurements[:duration]) %>
        </p>
      <% end %>

      <!-- Result details for deploy/upgrade stop events -->
      <%= if result = @event.metadata[:result] do %>
        <.result_detail result={result} />
      <% end %>

      <!-- Error details -->
      <%= if @event.metadata[:error] do %>
        <div class="mt-2 p-2 bg-red-900/30 rounded text-xs font-mono text-red-300 overflow-x-auto">
          <%= inspect(@event.metadata[:error], pretty: true, limit: 5) %>
        </div>
      <% end %>

      <!-- Git info -->
      <%= if @event.metadata[:branch] do %>
        <p class="text-gray-500 text-xs">
          Branch: <span class="text-gray-400"><%= @event.metadata[:branch] %></span>
        </p>
      <% end %>
    </div>
    """
  end

  attr :result, :any, required: true

  defp result_detail(assigns) do
    ~H"""
    <%= case @result do %>
      <% {:ok, app_state} when is_tuple(app_state) -> %>
        <div class="mt-1 text-xs text-green-400 flex items-center gap-1">
          <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"/>
          </svg>
          Success
        </div>
      <% {:error, reason} -> %>
        <div class="mt-2 p-2 bg-red-900/30 rounded text-xs">
          <p class="text-red-400 font-medium flex items-center gap-1">
            <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd"/>
            </svg>
            Failed
          </p>
          <p class="font-mono text-red-300 mt-1 overflow-x-auto"><%= format_error(reason) %></p>
        </div>
      <% _ -> %>
    <% end %>
    """
  end

  # Helpers

  defp has_http_endpoint?(app) when is_map(app) do
    env = app[:env] || %{}
    is_map(env) and (Map.has_key?(env, :http_port) or Map.has_key?(env, "http_port"))
  end

  defp has_http_endpoint?(_), do: false

  defp get_http_url(app) when is_map(app) do
    env = app[:env] || %{}
    port = env[:http_port] || env["http_port"] || 8080
    "http://localhost:#{port}"
  end

  defp get_http_url(_), do: nil

  defp health_color(:healthy), do: "text-green-400"
  defp health_color(:unhealthy), do: "text-red-400"
  defp health_color(_), do: "text-gray-400"

  defp format_started_at({{year, month, day}, {hour, min, sec}}) do
    "#{year}-#{pad(month)}-#{pad(day)} #{pad(hour)}:#{pad(min)}:#{pad(sec)}"
  end

  defp format_started_at(_), do: "-"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp format_duration(ns) when is_integer(ns) do
    cond do
      ns >= 1_000_000_000 -> "#{Float.round(ns / 1_000_000_000, 2)}s"
      ns >= 1_000_000 -> "#{Float.round(ns / 1_000_000, 2)}ms"
      ns >= 1_000 -> "#{Float.round(ns / 1_000, 2)}us"
      true -> "#{ns}ns"
    end
  end

  defp format_duration(_), do: nil

  defp format_error({:fetch_failed, {:git_clone_failed, {:exit_code, _, msg}}}) do
    String.trim(to_string(msg))
  end

  defp format_error({:fetch_failed, reason}), do: "Fetch failed: #{inspect(reason)}"
  defp format_error({:build_failed, reason}), do: "Build failed: #{inspect(reason)}"
  defp format_error({:start_failed, reason}), do: "Start failed: #{inspect(reason)}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason, limit: 3)

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

  defp event_text_color([:bc_gitops, :reconcile, :start]), do: "text-blue-400"
  defp event_text_color([:bc_gitops, :reconcile, :stop]), do: "text-green-400"
  defp event_text_color([:bc_gitops, :reconcile, :error]), do: "text-red-400"
  defp event_text_color([:bc_gitops, :deploy, :start]), do: "text-purple-400"
  defp event_text_color([:bc_gitops, :deploy, :stop]), do: "text-purple-300"
  defp event_text_color([:bc_gitops, :upgrade, _]), do: "text-yellow-400"
  defp event_text_color([:bc_gitops, :remove, _]), do: "text-orange-400"
  defp event_text_color(_), do: "text-gray-400"

  defp event_border_color([:bc_gitops, :reconcile, :start]), do: "border-blue-500"
  defp event_border_color([:bc_gitops, :reconcile, :stop]), do: "border-green-500"
  defp event_border_color([:bc_gitops, :reconcile, :error]), do: "border-red-500"
  defp event_border_color([:bc_gitops, :deploy, _]), do: "border-purple-500"
  defp event_border_color([:bc_gitops, :upgrade, _]), do: "border-yellow-500"
  defp event_border_color([:bc_gitops, :remove, _]), do: "border-orange-500"
  defp event_border_color(_), do: "border-gray-600"

  defp event_bg_color([:bc_gitops, :reconcile, :error]), do: "bg-red-900/20"
  defp event_bg_color([:bc_gitops, :deploy, :stop]), do: "bg-purple-900/10"
  defp event_bg_color(_), do: ""
end
