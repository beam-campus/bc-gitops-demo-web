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
    # erlexec returns data as charlist, convert to binary string for JSON
    binary_data = if is_list(data), do: IO.iodata_to_binary(data), else: data
    Logger.debug("[Terminal] stdout: #{inspect(binary_data, limit: 50)}")
    push(socket, "output", %{data: binary_data})
    {:noreply, socket}
  end

  def handle_info({:stderr, _os_pid, data}, socket) do
    # erlexec returns data as charlist, convert to binary string for JSON
    binary_data = if is_list(data), do: IO.iodata_to_binary(data), else: data
    Logger.debug("[Terminal] stderr received: #{byte_size(binary_data)} bytes")
    push(socket, "output", %{data: binary_data})
    {:noreply, socket}
  end

  def handle_info({:DOWN, _os_pid, :process, _pid, reason}, socket) do
    Logger.info("[Terminal] PTY process exited: #{inspect(reason)}")
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  # Catch-all to see what messages we're getting
  def handle_info(msg, socket) do
    Logger.warning("[Terminal] Unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:pty_pid] do
      :exec.stop(pid)
    end

    :ok
  end

  # Start a PTY process for the given app
  # Note: erlexec from hex.pm doesn't have PTY support compiled in,
  # so we use the `script` command as a PTY wrapper
  defp start_pty_process(app_name, cols, rows) do
    Logger.debug("[Terminal] Starting PTY for #{app_name} (#{cols}x#{rows})")

    # Get the command for the app
    case get_app_command(app_name) do
      {:ok, cmd, args, env} ->
        Logger.debug("[Terminal] Command: #{cmd}, Args: #{inspect(args)}")

        # Build the full command string for script wrapper
        full_cmd = Enum.join([cmd | args], " ")

        # Use script as a PTY wrapper since erlexec hex package lacks PTY support
        # script -q -c "command" /dev/null creates a pseudo-terminal
        opts = [
          :stdin,
          :stdout,
          :stderr,
          :monitor,
          {:env, env ++ [
            {"COLUMNS", to_string(cols)},
            {"LINES", to_string(rows)},
            {"TERM", "xterm-256color"}
          ]}
        ]

        # Wrap command with stty to set terminal size
        wrapped_cmd = "stty cols #{cols} rows #{rows} 2>/dev/null; #{full_cmd}"
        script_cmd = ["/usr/bin/script", "-q", "-c", wrapped_cmd, "/dev/null"]
        Logger.debug("[Terminal] Running via script: #{inspect(script_cmd)}")

        case :exec.run(script_cmd, opts) do
          {:ok, pid, os_pid} ->
            Logger.info("[Terminal] PTY started successfully, OS PID: #{os_pid}")
            {:ok, pid, os_pid}

          {:error, reason} ->
            Logger.error("[Terminal] exec.run failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[Terminal] get_app_command failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Determine command to run based on app name
  defp get_app_command("demo_tui") do
    # Find the demo_tui binary in the managed app's priv directory
    case find_demo_tui_binary() do
      {:ok, binary_path} ->
        Logger.info("[Terminal] Found demo_tui binary at: #{binary_path}")

        env = [
          {"TERM", "xterm-256color"},
          {"COUNTER_URL", "http://localhost:8082"}
        ]

        # Run binary directly - script wrapper provides PTY
        {:ok, binary_path, [], env}

      :error ->
        Logger.error("[Terminal] demo_tui binary not found in any search path")
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
    arch = get_arch()

    # Check common locations for the demo_tui binary
    paths = [
      # From bc_gitops managed app path
      get_managed_app_path("demo_tui"),
      # Development path (sibling repo)
      Path.expand("../../../../bc-gitops-demo-tui/priv/#{arch}/demo-tui", __DIR__),
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
