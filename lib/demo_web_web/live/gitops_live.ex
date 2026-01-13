defmodule DemoWebWeb.GitOpsLive do
  @moduledoc """
  LiveView for visualizing the GitOps repository state.

  Shows the source of truth (git repo specs) vs actual deployed state,
  with real-time reconciliation events.
  """
  use DemoWebWeb, :live_view

  require Logger

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DemoWeb.PubSub, "gitops:events")
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    socket =
      socket
      |> assign(:config, fetch_config())
      |> assign(:status, fetch_status())
      |> assign(:specs, fetch_specs())
      |> assign(:deployed, fetch_deployed())
      |> assign(:events, [])
      |> assign(:syncing, false)
      |> assign(:last_sync, nil)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> assign(:status, fetch_status())
      |> assign(:specs, fetch_specs())
      |> assign(:deployed, fetch_deployed())

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

    events = [event_entry | socket.assigns.events] |> Enum.take(100)

    {syncing, last_sync} =
      case event do
        [:bc_gitops, :reconcile, :start] -> {true, socket.assigns.last_sync}
        [:bc_gitops, :reconcile, :stop] -> {false, DateTime.utc_now()}
        [:bc_gitops, :reconcile, :error] -> {false, socket.assigns.last_sync}
        _ -> {socket.assigns.syncing, socket.assigns.last_sync}
      end

    socket =
      socket
      |> assign(:events, events)
      |> assign(:syncing, syncing)
      |> assign(:last_sync, last_sync)
      |> assign(:status, fetch_status())
      |> assign(:specs, fetch_specs())
      |> assign(:deployed, fetch_deployed())

    {:noreply, socket}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    spawn(fn -> :bc_gitops.reconcile() end)
    {:noreply, assign(socket, :syncing, true)}
  end

  # Data fetching

  defp fetch_config do
    %{
      repo_url: Application.get_env(:bc_gitops, :repo_url, "not configured"),
      branch: Application.get_env(:bc_gitops, :branch, "main"),
      local_path: Application.get_env(:bc_gitops, :local_path, "/var/lib/bc_gitops"),
      apps_dir: Application.get_env(:bc_gitops, :apps_dir, "apps"),
      reconcile_interval: Application.get_env(:bc_gitops, :reconcile_interval, 60_000)
    }
  end

  defp fetch_status do
    case :bc_gitops.status() do
      {:ok, status} -> status
      {:error, :busy} -> %{status: :busy, last_commit: nil, app_count: 0, healthy_count: 0}
      _ -> %{status: :unknown, last_commit: nil, app_count: 0, healthy_count: 0}
    end
  end

  defp fetch_specs do
    config = fetch_config()
    apps_path = Path.join(config.local_path, config.apps_dir)

    if File.dir?(apps_path) do
      apps_path
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(apps_path, &1)))
      |> Enum.map(fn app_dir ->
        app_path = Path.join(apps_path, app_dir)
        spec = read_app_spec(app_path)
        {String.to_atom(app_dir), spec}
      end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp read_app_spec(app_path) do
    config_files = ["app.config", "app.yaml", "app.yml", "app.json", "config.yaml", "config.json"]

    config_files
    |> Enum.map(&Path.join(app_path, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        %{error: "No config file found"}

      path ->
        case Path.extname(path) do
          ".config" -> parse_erlang_config(path)
          ext when ext in [".yaml", ".yml"] -> parse_yaml_config(path)
          ".json" -> parse_json_config(path)
          _ -> %{error: "Unknown config format"}
        end
    end
  end

  defp parse_erlang_config(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [spec]} when is_map(spec) -> normalize_spec(spec)
      {:ok, _} -> %{error: "Invalid config format"}
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp parse_yaml_config(path) do
    if Code.ensure_loaded?(:yamerl) do
      try do
        case :yamerl.decode_file(String.to_charlist(path)) do
          [[_ | _] = doc] -> normalize_spec(proplist_to_map(doc))
          _ -> %{error: "Invalid YAML"}
        end
      rescue
        e -> %{error: Exception.message(e)}
      end
    else
      %{error: "YAML support not available (yamerl not loaded)"}
    end
  end

  defp parse_json_config(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, spec} -> normalize_spec(spec)
          {:error, reason} -> %{error: inspect(reason)}
        end

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  defp proplist_to_map(proplist) when is_list(proplist) do
    if Keyword.keyword?(proplist) or proplist_like?(proplist) do
      Map.new(proplist, fn
        {k, v} when is_list(v) -> {to_string(k), proplist_to_map(v)}
        {k, v} -> {to_string(k), v}
      end)
    else
      Enum.map(proplist, &proplist_to_map/1)
    end
  end

  defp proplist_to_map(other), do: other

  defp proplist_like?([{_, _} | _]), do: true
  defp proplist_like?(_), do: false

  defp normalize_spec(spec) when is_map(spec) do
    %{
      name: get_key(spec, [:name]),
      version: get_key(spec, [:version]),
      source: normalize_source(get_key(spec, [:source])),
      env: get_key(spec, [:env]) || %{},
      health: get_key(spec, [:health]),
      depends_on: get_key(spec, [:depends_on]) || []
    }
  end

  defp normalize_spec(_), do: %{error: "Invalid spec format"}

  defp normalize_source(nil), do: nil

  defp normalize_source(source) when is_map(source) do
    %{
      type: get_key(source, [:type]),
      url: get_key(source, [:url]),
      ref: get_key(source, [:ref]),
      package: get_key(source, [:package])
    }
  end

  defp normalize_source(_), do: nil

  defp get_key(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key)) || Map.get(map, :"#{key}")
    end)
  end

  defp get_key(_, _), do: nil

  defp fetch_deployed do
    try do
      case :bc_gitops.get_current_state() do
        {:ok, apps} when is_map(apps) ->
          Map.new(apps, fn {name, app} -> {name, record_to_map(app)} end)

        _ ->
          %{}
      end
    catch
      :exit, {:timeout, _} -> %{}
    end
  end

  # New 11-element app_state record (bc_gitops v0.5.0+)
  defp record_to_map({:app_state, name, version, description, icon, status, path, pid, started_at, health, env}) do
    %{
      name: name,
      version: version,
      description: description,
      icon: icon,
      status: status,
      path: path,
      pid: pid,
      started_at: started_at,
      health: health,
      env: env
    }
  end

  # Legacy 9-element app_state record (bc_gitops < v0.5.0)
  defp record_to_map({:app_state, name, version, status, path, pid, started_at, health, env}) do
    %{
      name: name,
      version: version,
      description: nil,
      icon: nil,
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

  # Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-gray-100">
      <header class="bg-gray-800 shadow-lg border-b border-gray-700">
        <div class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
          <div class="flex justify-between items-center">
            <div class="flex items-center gap-4">
              <.link navigate={~p"/"} class="text-gray-400 hover:text-white transition-colors">
                <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
                </svg>
              </.link>
              <div>
                <h1 class="text-3xl font-bold text-white flex items-center gap-3">
                  <svg class="w-8 h-8 text-orange-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"/>
                  </svg>
                  GitOps Repository
                </h1>
                <p class="text-gray-400 mt-1">Source of truth for managed applications</p>
              </div>
            </div>
            <div class="flex items-center gap-4">
              <%= if @last_sync do %>
                <span class="text-sm text-gray-500">
                  Last sync: <%= Calendar.strftime(@last_sync, "%H:%M:%S") %>
                </span>
              <% end %>
              <button
                phx-click="sync"
                disabled={@syncing}
                class={"px-4 py-2 rounded-lg font-medium transition-colors " <>
                  if @syncing do
                    "bg-gray-600 text-gray-400 cursor-not-allowed"
                  else
                    "bg-orange-600 hover:bg-orange-700 text-white"
                  end}
              >
                <%= if @syncing do %>
                  <span class="flex items-center gap-2">
                    <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
                    </svg>
                    Reconciling...
                  </span>
                <% else %>
                  Reconcile Now
                <% end %>
              </button>
            </div>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
        <!-- Repository Configuration -->
        <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700 mb-8">
          <div class="px-6 py-4 border-b border-gray-700">
            <h2 class="text-xl font-semibold text-white flex items-center gap-2">
              <svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"/>
              </svg>
              Repository Configuration
            </h2>
          </div>
          <div class="p-6 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <.config_item label="Repository URL" value={@config.repo_url} icon="git" />
            <.config_item label="Branch" value={@config.branch} icon="branch" />
            <.config_item label="Local Path" value={@config.local_path} icon="folder" />
            <.config_item label="Apps Directory" value={@config.apps_dir} icon="apps" />
            <.config_item label="Reconcile Interval" value={"#{div(@config.reconcile_interval, 1000)}s"} icon="clock" />
            <.config_item label="Last Commit" value={truncate(@status[:last_commit], 12)} icon="commit" />
          </div>
        </div>

        <!-- Desired vs Actual State -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
          <!-- Desired State (from repo) -->
          <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
            <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
              <h2 class="text-xl font-semibold text-white flex items-center gap-2">
                <span class="w-3 h-3 bg-blue-500 rounded-full"></span>
                Desired State
              </h2>
              <span class="text-sm text-gray-500"><%= map_size(@specs) %> apps</span>
            </div>
            <div class="p-6">
              <%= if map_size(@specs) == 0 do %>
                <.empty_state message="No app specs found in repository" />
              <% else %>
                <div class="space-y-4">
                  <%= for {name, spec} <- @specs do %>
                    <.spec_card name={name} spec={spec} deployed={@deployed[name]} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Actual State (deployed) -->
          <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
            <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
              <h2 class="text-xl font-semibold text-white flex items-center gap-2">
                <span class="w-3 h-3 bg-green-500 rounded-full"></span>
                Actual State
              </h2>
              <span class="text-sm text-gray-500"><%= map_size(@deployed) %> running</span>
            </div>
            <div class="p-6">
              <%= if map_size(@deployed) == 0 do %>
                <.empty_state message="No applications deployed yet" />
              <% else %>
                <div class="space-y-4">
                  <%= for {name, app} <- @deployed do %>
                    <.deployed_card name={name} app={app} spec={@specs[name]} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Reconciliation Events -->
        <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
          <div class="px-6 py-4 border-b border-gray-700 flex justify-between items-center">
            <h2 class="text-xl font-semibold text-white flex items-center gap-2">
              <svg class="w-5 h-5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
              </svg>
              Reconciliation Events
            </h2>
            <span class="text-sm text-gray-500"><%= length(@events) %> events</span>
          </div>
          <div class="p-6 max-h-96 overflow-y-auto">
            <%= if @events == [] do %>
              <.empty_state message="Waiting for reconciliation events..." />
            <% else %>
              <div class="space-y-2">
                <%= for event <- @events do %>
                  <.event_row event={event} />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # Components

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, default: "info"

  defp config_item(assigns) do
    ~H"""
    <div class="bg-gray-750 rounded-lg p-4 border border-gray-600">
      <div class="flex items-center gap-2 mb-2">
        <.config_icon icon={@icon} />
        <span class="text-sm text-gray-400"><%= @label %></span>
      </div>
      <p class="font-mono text-sm text-white truncate" title={@value}><%= @value || "-" %></p>
    </div>
    """
  end

  attr :icon, :string, required: true

  defp config_icon(%{icon: "git"} = assigns) do
    ~H"""
    <svg class="w-4 h-4 text-orange-400" fill="currentColor" viewBox="0 0 24 24">
      <path d="M21.62 11.108l-8.731-8.729a1.292 1.292 0 00-1.823 0L9.257 4.19l2.299 2.3a1.532 1.532 0 011.939 1.95l2.214 2.215a1.53 1.53 0 011.583 2.531 1.534 1.534 0 01-2.119-.024 1.536 1.536 0 01-.336-1.683l-2.064-2.065v5.427a1.535 1.535 0 01.406 2.533 1.534 1.534 0 11-1.538-2.533V9.4a1.532 1.532 0 01-.832-2.012L8.5 5.076l-6.123 6.123a1.29 1.29 0 000 1.823l8.731 8.729a1.29 1.29 0 001.823 0l8.689-8.82a1.29 1.29 0 000-1.823z"/>
    </svg>
    """
  end

  defp config_icon(%{icon: "branch"} = assigns) do
    ~H"""
    <svg class="w-4 h-4 text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
    </svg>
    """
  end

  defp config_icon(%{icon: "folder"} = assigns) do
    ~H"""
    <svg class="w-4 h-4 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"/>
    </svg>
    """
  end

  defp config_icon(%{icon: "apps"} = assigns) do
    ~H"""
    <svg class="w-4 h-4 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z"/>
    </svg>
    """
  end

  defp config_icon(%{icon: "clock"} = assigns) do
    ~H"""
    <svg class="w-4 h-4 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/>
    </svg>
    """
  end

  defp config_icon(%{icon: "commit"} = assigns) do
    ~H"""
    <svg class="w-4 h-4 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
    </svg>
    """
  end

  defp config_icon(assigns) do
    ~H"""
    <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
    </svg>
    """
  end

  attr :name, :atom, required: true
  attr :spec, :map, required: true
  attr :deployed, :map, default: nil

  defp spec_card(assigns) do
    sync_status = get_sync_status(assigns.spec, assigns.deployed)
    assigns = assign(assigns, :sync_status, sync_status)

    ~H"""
    <div class={"rounded-lg border p-4 " <> spec_card_class(@sync_status)}>
      <div class="flex justify-between items-start mb-2">
        <div>
          <h3 class="font-semibold text-white"><%= @name %></h3>
          <%= if @spec[:version] do %>
            <span class="text-sm text-blue-400">v<%= @spec[:version] %></span>
          <% end %>
        </div>
        <.sync_badge status={@sync_status} />
      </div>

      <%= if @spec[:error] do %>
        <p class="text-red-400 text-sm"><%= @spec[:error] %></p>
      <% else %>
        <%= if @spec[:source] do %>
          <.source_info source={@spec.source} app_name={@name} />
        <% end %>

        <%= if @spec[:depends_on] != [] do %>
          <div class="mt-2 text-xs">
            <span class="text-gray-500">Depends:</span>
            <span class="text-gray-300 ml-1"><%= Enum.join(@spec[:depends_on], ", ") %></span>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :app, :map, required: true
  attr :spec, :map, default: nil

  defp deployed_card(assigns) do
    sync_status = get_sync_status(assigns.spec, assigns.app)
    assigns = assign(assigns, :sync_status, sync_status)

    ~H"""
    <div class={"rounded-lg border p-4 " <> deployed_card_class(@app[:status])}>
      <div class="flex justify-between items-start mb-2">
        <div>
          <h3 class="font-semibold text-white"><%= @name %></h3>
          <span class="text-sm text-green-400">v<%= @app[:version] %></span>
        </div>
        <span class={status_badge_class(@app[:status])}>
          <%= @app[:status] %>
        </span>
      </div>

      <div class="grid grid-cols-2 gap-2 mt-2 text-xs">
        <div>
          <span class="text-gray-500">Health:</span>
          <span class={health_color(@app[:health])}><%= @app[:health] || :unknown %></span>
        </div>
        <div>
          <span class="text-gray-500">PID:</span>
          <span class="text-gray-300 font-mono"><%= format_pid(@app[:pid]) %></span>
        </div>
      </div>

      <%= if @spec == nil do %>
        <div class="mt-2 text-xs text-yellow-400">
          ⚠ No spec in repo (orphaned)
        </div>
      <% end %>
    </div>
    """
  end

  attr :event, :map, required: true

  defp event_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-sm py-2 border-b border-gray-700 last:border-0">
      <span class="text-gray-500 text-xs w-20">
        <%= Calendar.strftime(@event.timestamp, "%H:%M:%S") %>
      </span>
      <span class={event_dot_class(@event.event)}></span>
      <span class={event_text_class(@event.event)}>
        <%= event_label(@event.event) %>
      </span>
      <%= if @event.metadata[:app] do %>
        <span class="text-gray-400">•</span>
        <span class="text-white font-medium"><%= @event.metadata[:app] %></span>
      <% end %>
      <%= if @event.measurements[:duration] do %>
        <span class="text-gray-500 ml-auto"><%= format_duration(@event.measurements[:duration]) %></span>
      <% end %>
    </div>
    """
  end

  attr :message, :string, required: true

  defp empty_state(assigns) do
    ~H"""
    <div class="text-center py-8 text-gray-500">
      <svg class="mx-auto h-12 w-12 text-gray-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4"/>
      </svg>
      <p class="mt-2"><%= @message %></p>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp sync_badge(assigns) do
    ~H"""
    <span class={sync_badge_class(@status)}>
      <%= sync_label(@status) %>
    </span>
    """
  end

  attr :source, :map, required: true
  attr :app_name, :atom, default: nil

  defp source_info(assigns) do
    parsed = parse_source(assigns.source, assigns.app_name)
    assigns = assign(assigns, :parsed, parsed)

    ~H"""
    <div class="mt-3 bg-gray-800 rounded-lg p-3 border border-gray-600 text-xs">
      <!-- Type + Host + Ref on one row -->
      <div class="flex items-center gap-2">
        <span class={source_type_badge(@parsed.type)}>
          <.source_type_icon type={@parsed.type} />
          <%= @parsed.type %>
        </span>
        <span class="text-gray-300"><%= @parsed.host %></span>
        <%= if @source[:ref] do %>
          <span class="ml-auto px-2 py-0.5 rounded bg-yellow-900/50 text-yellow-300 font-mono">
            @<%= truncate(to_string(@source[:ref]), 12) %>
          </span>
        <% end %>
      </div>
      <!-- Package path -->
      <div class={"mt-1.5 font-mono truncate " <> source_path_color(@parsed.type)} title={@parsed.path}>
        <%= @parsed.path %>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp source_type_icon(%{type: :git} = assigns) do
    ~H"""
    <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
      <path d="M21.62 11.108l-8.731-8.729a1.292 1.292 0 00-1.823 0L9.257 4.19l2.299 2.3a1.532 1.532 0 011.939 1.95l2.214 2.215a1.53 1.53 0 011.583 2.531 1.534 1.534 0 01-2.119-.024 1.536 1.536 0 01-.336-1.683l-2.064-2.065v5.427a1.535 1.535 0 01.406 2.533 1.534 1.534 0 11-1.538-2.533V9.4a1.532 1.532 0 01-.832-2.012L8.5 5.076l-6.123 6.123a1.29 1.29 0 000 1.823l8.731 8.729a1.29 1.29 0 001.823 0l8.689-8.82a1.29 1.29 0 000-1.823z"/>
    </svg>
    """
  end

  defp source_type_icon(%{type: :hex} = assigns) do
    ~H"""
    <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 2L3 7v10l9 5 9-5V7l-9-5zm0 2.18l6.56 3.64L12 11.46 5.44 7.82 12 4.18zM5 9.64l6 3.33v6.36l-6-3.33V9.64zm14 6.36l-6 3.33v-6.36l6-3.33v6.36z"/>
    </svg>
    """
  end

  defp source_type_icon(assigns) do
    ~H"""
    <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
    </svg>
    """
  end

  # Helpers

  defp parse_source(source, app_name \\ nil)

  defp parse_source(source, app_name) when is_map(source) do
    type = source[:type] || :unknown
    url = to_string(source[:url] || "")

    case type do
      :git -> parse_git_url(url)
      :hex -> parse_hex_source(source, app_name)
      _ -> %{type: type, host: "unknown", path: url}
    end
  end

  defp parse_source(_, _), do: %{type: :unknown, host: "unknown", path: ""}

  defp parse_git_url(url) do
    # Handle various git URL formats
    cond do
      String.contains?(url, "github.com") ->
        path = extract_git_path(url, "github.com")
        %{type: :git, host: "github.com", path: path}

      String.contains?(url, "gitlab.com") ->
        path = extract_git_path(url, "gitlab.com")
        %{type: :git, host: "gitlab.com", path: path}

      String.contains?(url, "bitbucket.org") ->
        path = extract_git_path(url, "bitbucket.org")
        %{type: :git, host: "bitbucket.org", path: path}

      true ->
        # Generic git URL
        case URI.parse(url) do
          %{host: host, path: path} when is_binary(host) ->
            %{type: :git, host: host, path: clean_git_path(path)}
          _ ->
            %{type: :git, host: "git", path: url}
        end
    end
  end

  defp extract_git_path(url, host) do
    url
    |> String.split(host)
    |> List.last()
    |> clean_git_path()
  end

  defp clean_git_path(nil), do: ""
  defp clean_git_path(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_leading(":")
    |> String.trim_trailing(".git")
    |> then(&("/" <> &1))
  end

  defp parse_hex_source(source, app_name) do
    package = source[:package] || app_name || "unknown"
    %{type: :hex, host: "hex.pm", path: "/packages/#{package}"}
  end

  defp source_type_badge(:git), do: "inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-orange-900/50 text-orange-300"
  defp source_type_badge(:hex), do: "inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-purple-900/50 text-purple-300"
  defp source_type_badge(_), do: "inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-gray-700 text-gray-300"

  defp source_path_color(:git), do: "text-orange-400"
  defp source_path_color(:hex), do: "text-purple-400"
  defp source_path_color(_), do: "text-gray-400"

  defp get_sync_status(nil, _deployed), do: :no_spec
  defp get_sync_status(_spec, nil), do: :not_deployed
  defp get_sync_status(%{error: _}, _), do: :error
  defp get_sync_status(%{version: spec_v}, %{version: deployed_v}) when spec_v == deployed_v, do: :synced
  defp get_sync_status(_, _), do: :out_of_sync

  defp sync_label(:synced), do: "Synced"
  defp sync_label(:out_of_sync), do: "Update pending"
  defp sync_label(:not_deployed), do: "Not deployed"
  defp sync_label(:no_spec), do: "Orphaned"
  defp sync_label(:error), do: "Error"

  defp sync_badge_class(:synced), do: "px-2 py-0.5 text-xs rounded-full bg-green-900 text-green-300"
  defp sync_badge_class(:out_of_sync), do: "px-2 py-0.5 text-xs rounded-full bg-yellow-900 text-yellow-300"
  defp sync_badge_class(:not_deployed), do: "px-2 py-0.5 text-xs rounded-full bg-blue-900 text-blue-300"
  defp sync_badge_class(:no_spec), do: "px-2 py-0.5 text-xs rounded-full bg-orange-900 text-orange-300"
  defp sync_badge_class(:error), do: "px-2 py-0.5 text-xs rounded-full bg-red-900 text-red-300"

  defp spec_card_class(:synced), do: "bg-gray-750 border-green-700"
  defp spec_card_class(:out_of_sync), do: "bg-gray-750 border-yellow-700"
  defp spec_card_class(:not_deployed), do: "bg-gray-750 border-blue-700"
  defp spec_card_class(:error), do: "bg-gray-750 border-red-700"
  defp spec_card_class(_), do: "bg-gray-750 border-gray-600"

  defp deployed_card_class(:running), do: "bg-gray-750 border-green-700"
  defp deployed_card_class(:stopped), do: "bg-gray-750 border-gray-600"
  defp deployed_card_class(:failed), do: "bg-gray-750 border-red-700"
  defp deployed_card_class(_), do: "bg-gray-750 border-gray-600"

  defp status_badge_class(:running), do: "px-2 py-0.5 text-xs rounded-full bg-green-900 text-green-300"
  defp status_badge_class(:stopped), do: "px-2 py-0.5 text-xs rounded-full bg-gray-700 text-gray-300"
  defp status_badge_class(:failed), do: "px-2 py-0.5 text-xs rounded-full bg-red-900 text-red-300"
  defp status_badge_class(_), do: "px-2 py-0.5 text-xs rounded-full bg-gray-700 text-gray-300"

  defp source_color(:git), do: "text-orange-400"
  defp source_color(:hex), do: "text-purple-400"
  defp source_color(_), do: "text-gray-400"

  defp health_color(:healthy), do: "text-green-400 ml-1"
  defp health_color(:unhealthy), do: "text-red-400 ml-1"
  defp health_color(_), do: "text-gray-400 ml-1"

  defp event_label([:bc_gitops, :reconcile, :start]), do: "Reconcile started"
  defp event_label([:bc_gitops, :reconcile, :stop]), do: "Reconcile complete"
  defp event_label([:bc_gitops, :reconcile, :error]), do: "Reconcile error"
  defp event_label([:bc_gitops, :deploy, :start]), do: "Deploy"
  defp event_label([:bc_gitops, :deploy, :stop]), do: "Deployed"
  defp event_label([:bc_gitops, :upgrade, :start]), do: "Upgrade"
  defp event_label([:bc_gitops, :upgrade, :stop]), do: "Upgraded"
  defp event_label([:bc_gitops, :remove, :start]), do: "Remove"
  defp event_label([:bc_gitops, :remove, :stop]), do: "Removed"
  defp event_label([:bc_gitops, :git, :pull]), do: "Git pull"
  defp event_label([:bc_gitops, :git, :clone_start]), do: "Git clone"
  defp event_label([:bc_gitops, :git, :clone_stop]), do: "Cloned"
  defp event_label([:bc_gitops, :deps, :start]), do: "Fetching deps"
  defp event_label([:bc_gitops, :deps, :stop]), do: "Deps fetched"
  defp event_label([:bc_gitops, :build, :start]), do: "Building"
  defp event_label([:bc_gitops, :build, :stop]), do: "Built"
  defp event_label([:bc_gitops, :code, :load]), do: "Code loaded"
  defp event_label(event), do: inspect(event)

  defp event_dot_class([:bc_gitops, :reconcile, :start]), do: "w-2 h-2 rounded-full bg-blue-400"
  defp event_dot_class([:bc_gitops, :reconcile, :stop]), do: "w-2 h-2 rounded-full bg-green-400"
  defp event_dot_class([:bc_gitops, :reconcile, :error]), do: "w-2 h-2 rounded-full bg-red-400"
  defp event_dot_class([:bc_gitops, :deploy, _]), do: "w-2 h-2 rounded-full bg-purple-400"
  defp event_dot_class([:bc_gitops, :upgrade, _]), do: "w-2 h-2 rounded-full bg-yellow-400"
  defp event_dot_class([:bc_gitops, :remove, _]), do: "w-2 h-2 rounded-full bg-orange-400"
  defp event_dot_class([:bc_gitops, :git, _]), do: "w-2 h-2 rounded-full bg-cyan-400"
  defp event_dot_class([:bc_gitops, :deps, _]), do: "w-2 h-2 rounded-full bg-indigo-400"
  defp event_dot_class([:bc_gitops, :build, _]), do: "w-2 h-2 rounded-full bg-amber-400"
  defp event_dot_class([:bc_gitops, :code, _]), do: "w-2 h-2 rounded-full bg-emerald-400"
  defp event_dot_class(_), do: "w-2 h-2 rounded-full bg-gray-400"

  defp event_text_class([:bc_gitops, :reconcile, :error]), do: "text-red-400"
  defp event_text_class(_), do: "text-gray-300"

  defp format_pid(pid) when is_pid(pid), do: inspect(pid)
  defp format_pid(_), do: "-"

  defp format_duration(ns) when is_integer(ns) do
    cond do
      ns >= 1_000_000_000 -> "#{Float.round(ns / 1_000_000_000, 2)}s"
      ns >= 1_000_000 -> "#{Float.round(ns / 1_000_000, 2)}ms"
      ns >= 1_000 -> "#{Float.round(ns / 1_000, 2)}μs"
      true -> "#{ns}ns"
    end
  end

  defp format_duration(_), do: nil

  defp truncate(nil, _), do: "-"
  defp truncate(str, len) when is_binary(str) and byte_size(str) > len, do: String.slice(str, 0, len) <> "..."
  defp truncate(str, _) when is_binary(str), do: str
  defp truncate(_, _), do: "-"
end
