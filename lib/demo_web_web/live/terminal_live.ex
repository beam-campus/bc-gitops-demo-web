defmodule DemoWebWeb.TerminalLive do
  @moduledoc """
  LiveView for embedded terminal access to managed applications.

  Supports running TUI applications like demo_tui directly in the browser
  via xterm.js + PTY.
  """
  use DemoWebWeb, :live_view

  @impl true
  def mount(%{"app" => app_name}, _session, socket) do
    socket =
      socket
      |> assign(:app_name, app_name)
      |> assign(:page_title, "Terminal: #{app_name}")

    {:ok, socket}
  end

  def mount(_params, _session, socket) do
    # Default to shell if no app specified
    socket =
      socket
      |> assign(:app_name, "shell")
      |> assign(:page_title, "Terminal")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-gray-100">
      <header class="bg-gray-800 shadow-lg border-b border-gray-700">
        <div class="max-w-7xl mx-auto py-4 px-4 sm:px-6 lg:px-8">
          <div class="flex justify-between items-center">
            <div class="flex items-center gap-4">
              <.link
                navigate={~p"/"}
                class="p-2 hover:bg-gray-700 rounded-lg transition-colors"
                title="Back to Dashboard"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
                </svg>
              </.link>
              <div>
                <h1 class="text-xl font-bold text-white flex items-center gap-2">
                  <svg class="w-5 h-5 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                  </svg>
                  Terminal: <span class="text-cyan-400"><%= @app_name %></span>
                </h1>
                <p class="text-sm text-gray-400">Interactive TUI in browser via PTY</p>
              </div>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-xs text-gray-500 font-mono">
                xterm.js + erlexec
              </span>
            </div>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
        <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700 overflow-hidden">
          <!-- Terminal Header -->
          <div class="px-4 py-2 bg-gray-900 border-b border-gray-700 flex items-center gap-2">
            <div class="flex gap-1.5">
              <div class="w-3 h-3 rounded-full bg-red-500"></div>
              <div class="w-3 h-3 rounded-full bg-yellow-500"></div>
              <div class="w-3 h-3 rounded-full bg-green-500"></div>
            </div>
            <span class="ml-2 text-sm text-gray-400 font-mono"><%= @app_name %></span>
          </div>

          <!-- Terminal Container -->
          <div
            id="terminal"
            phx-hook="Terminal"
            data-app={@app_name}
            class="terminal-container"
            style="height: calc(100vh - 220px); min-height: 400px;"
            phx-update="ignore"
          >
          </div>
        </div>

        <!-- Help Section -->
        <div class="mt-6 bg-gray-800 rounded-lg p-4 border border-gray-700">
          <h3 class="text-sm font-medium text-gray-300 mb-2">Keyboard Shortcuts</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
            <%= if @app_name == "demo_tui" do %>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">i</kbd>
                <span class="text-gray-400 ml-2">Increment</span>
              </div>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">r</kbd>
                <span class="text-gray-400 ml-2">Reset</span>
              </div>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">Space</kbd>
                <span class="text-gray-400 ml-2">Refresh</span>
              </div>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">q</kbd>
                <span class="text-gray-400 ml-2">Quit</span>
              </div>
            <% else %>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">Ctrl+C</kbd>
                <span class="text-gray-400 ml-2">Interrupt</span>
              </div>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">Ctrl+D</kbd>
                <span class="text-gray-400 ml-2">EOF/Exit</span>
              </div>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">Ctrl+L</kbd>
                <span class="text-gray-400 ml-2">Clear</span>
              </div>
              <div>
                <kbd class="px-2 py-1 bg-gray-700 rounded text-xs font-mono">Tab</kbd>
                <span class="text-gray-400 ml-2">Autocomplete</span>
              </div>
            <% end %>
          </div>
        </div>
      </main>
    </div>
    """
  end
end
