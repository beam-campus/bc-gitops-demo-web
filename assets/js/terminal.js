import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"
import { Socket } from "phoenix"

/**
 * Terminal Hook for Phoenix LiveView
 *
 * Usage in HEEx:
 *   <div id="terminal" phx-hook="Terminal" data-app="demo_tui"></div>
 */
export const TerminalHook = {
  mounted() {
    const appName = this.el.dataset.app || "shell"
    const container = this.el

    // Create terminal instance
    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: '"JetBrains Mono", "Fira Code", "Cascadia Code", Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: "#1a1b26",
        foreground: "#c0caf5",
        cursor: "#c0caf5",
        cursorAccent: "#1a1b26",
        selection: "#33467c",
        black: "#15161e",
        red: "#f7768e",
        green: "#9ece6a",
        yellow: "#e0af68",
        blue: "#7aa2f7",
        magenta: "#bb9af7",
        cyan: "#7dcfff",
        white: "#a9b1d6",
        brightBlack: "#414868",
        brightRed: "#f7768e",
        brightGreen: "#9ece6a",
        brightYellow: "#e0af68",
        brightBlue: "#7aa2f7",
        brightMagenta: "#bb9af7",
        brightCyan: "#7dcfff",
        brightWhite: "#c0caf5"
      }
    })

    // Add addons
    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.loadAddon(new WebLinksAddon())

    // Open terminal in container
    this.term.open(container)
    this.fitAddon.fit()

    // Connect to Phoenix channel
    this.connectToChannel(appName)

    // Handle window resize
    this.resizeHandler = () => {
      this.fitAddon.fit()
      this.sendResize()
    }
    window.addEventListener("resize", this.resizeHandler)

    // Handle container resize via ResizeObserver
    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
      this.sendResize()
    })
    this.resizeObserver.observe(container)

    // Handle terminal input
    this.term.onData(data => {
      if (this.channel && this.channelJoined) {
        this.channel.push("input", { data: data })
      }
    })

    // Initial welcome message
    this.term.writeln("\x1b[1;34m╭───────────────────────────────────────╮\x1b[0m")
    this.term.writeln("\x1b[1;34m│\x1b[0m  \x1b[1;33mbc_gitops Terminal\x1b[0m                  \x1b[1;34m│\x1b[0m")
    this.term.writeln("\x1b[1;34m│\x1b[0m  Connecting to: \x1b[1;36m" + appName.padEnd(22) + "\x1b[0m\x1b[1;34m│\x1b[0m")
    this.term.writeln("\x1b[1;34m╰───────────────────────────────────────╯\x1b[0m")
    this.term.writeln("")
  },

  connectToChannel(appName) {
    // Create socket connection
    this.socket = new Socket("/terminal", {})
    this.socket.connect()

    // Join the terminal channel
    this.channel = this.socket.channel(`terminal:${appName}`, {
      cols: this.term.cols,
      rows: this.term.rows
    })

    this.channel.on("output", ({ data }) => {
      this.term.write(data)
    })

    this.channel.on("exit", ({ reason }) => {
      this.term.writeln("")
      this.term.writeln("\x1b[1;31m[Process exited: " + reason + "]\x1b[0m")
      this.term.writeln("\x1b[90mReload the page to reconnect.\x1b[0m")
      this.channelJoined = false
    })

    this.channel.join()
      .receive("ok", () => {
        this.channelJoined = true
        this.term.writeln("\x1b[1;32m[Connected]\x1b[0m")
        this.term.writeln("")
        this.sendResize()
        this.term.focus()
      })
      .receive("error", ({ reason }) => {
        this.channelJoined = false
        this.term.writeln("\x1b[1;31m[Connection failed: " + reason + "]\x1b[0m")
        this.term.writeln("\x1b[90mCheck that the application is running and try again.\x1b[0m")
      })
  },

  sendResize() {
    if (this.channel && this.channelJoined) {
      this.channel.push("resize", {
        cols: this.term.cols,
        rows: this.term.rows
      })
    }
  },

  destroyed() {
    // Cleanup
    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (this.channel) {
      this.channel.leave()
    }
    if (this.socket) {
      this.socket.disconnect()
    }
    if (this.term) {
      this.term.dispose()
    }
  }
}

export default TerminalHook
