defmodule DemoWebWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel for interactive terminal access via PTY.

  Uses erlexec to spawn a PTY process and relay I/O over WebSocket.
  Supports running managed applications' TUI components in the browser.
  """
  use DemoWebWeb, :channel

  require Logger

  @impl true
  def join("terminal:" <> app_name, payload, socket) do
    cols = payload["cols"] || 80
    rows = payload["rows"] || 24

    case start_pty_process(app_name, cols, rows) do
      {:ok, pid, os_pid} ->
        socket =
          socket
          |> assign(:pty_pid, pid)
          |> assign(:os_pid, os_pid)
          |> assign(:app_name, app_name)

        Logger.info("[Terminal] Started PTY for #{app_name}, OS PID: #{os_pid}")
        {:ok, socket}

      {:error, reason} ->
        Logger.error("[Terminal] Failed to start PTY for #{app_name}: #{inspect(reason)}")
        {:error, %{reason: "Failed to start terminal: #{inspect(reason)}"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    pid = socket.assigns[:pty_pid]

    if pid do
      # Send input to the PTY process
      :exec.send(pid, data)
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    os_pid = socket.assigns[:os_pid]

    if os_pid do
      # Resize the PTY window
      :exec.winsz(os_pid, rows, cols)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stdout, _os_pid, data}, socket) do
    push(socket, "output", %{data: data})
    {:noreply, socket}
  end

  def handle_info({:stderr, _os_pid, data}, socket) do
    push(socket, "output", %{data: data})
    {:noreply, socket}
  end

  def handle_info({:DOWN, _os_pid, :process, _pid, reason}, socket) do
    Logger.info("[Terminal] PTY process exited: #{inspect(reason)}")
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:pty_pid] do
      :exec.stop(pid)
    end

    :ok
  end

  # Start a PTY process for the given app
  defp start_pty_process(app_name, cols, rows) do
    # Get the command for the app
    case get_app_command(app_name) do
      {:ok, cmd, args, env} ->
        opts = [
          :stdin,
          :stdout,
          :stderr,
          :monitor,
          {:pty, true},
          {:env, env},
          {:winsz, {rows, cols}}
        ]

        case :exec.run([cmd | args], opts) do
          {:ok, pid, os_pid} ->
            {:ok, pid, os_pid}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Determine command to run based on app name
  defp get_app_command("demo_tui") do
    # Find the demo_tui binary in the managed app's priv directory
    case find_demo_tui_binary() do
      {:ok, binary_path} ->
        env = [
          {"TERM", "xterm-256color"},
          {"COUNTER_URL", "http://localhost:8082"}
        ]

        {:ok, binary_path, [], env}

      :error ->
        {:error, :binary_not_found}
    end
  end

  defp get_app_command("shell") do
    # Generic shell access (use with caution in production)
    shell = System.get_env("SHELL") || "/bin/bash"
    env = [{"TERM", "xterm-256color"}]
    {:ok, shell, [], env}
  end

  defp get_app_command(_app_name) do
    {:error, :unknown_app}
  end

  defp find_demo_tui_binary do
    # Check common locations for the demo_tui binary
    paths = [
      # From bc_gitops managed app path
      get_managed_app_path("demo_tui"),
      # Development path
      Path.expand("../bc-gitops-demo-tui/priv/linux-x86_64/demo-tui", __DIR__),
      # System path
      System.find_executable("demo-tui")
    ]

    paths
    |> Enum.filter(&(&1 != nil))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp get_managed_app_path(app_name) do
    # Try to get path from bc_gitops
    try do
      case :bc_gitops.get_current_state() do
        {:ok, apps} when is_map(apps) ->
          app_atom = String.to_existing_atom(app_name)

          case apps[app_atom] do
            {:app_state, _name, _version, _status, path, _pid, _started, _health, _env}
            when is_binary(path) ->
              # Look for binary in priv directory
              arch = get_arch()
              Path.join([path, "priv", arch, "demo-tui"])

            _ ->
              nil
          end

        _ ->
          nil
      end
    catch
      _, _ -> nil
    end
  end

  defp get_arch do
    case {:os.type(), :erlang.system_info(:system_architecture)} do
      {{:unix, :linux}, arch} when is_list(arch) ->
        arch_str = List.to_string(arch)

        cond do
          String.contains?(arch_str, "x86_64") -> "linux-x86_64"
          String.contains?(arch_str, "aarch64") -> "linux-aarch64"
          true -> "linux-x86_64"
        end

      {{:unix, :darwin}, arch} when is_list(arch) ->
        arch_str = List.to_string(arch)

        cond do
          String.contains?(arch_str, "x86_64") -> "macos-x86_64"
          String.contains?(arch_str, "aarch64") or String.contains?(arch_str, "arm") ->
            "macos-aarch64"
          true -> "macos-x86_64"
        end

      _ ->
        "linux-x86_64"
    end
  end
end
