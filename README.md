# bc-gitops-demo-web

Phoenix LiveView dashboard for [bc_gitops](https://github.com/beam-campus/bc-gitops) demonstration.

## Overview

This application is the **host** for bc_gitops. It:

1. Starts bc_gitops as a dependency
2. Configures it to watch [bc-gitops-demo-repo](https://github.com/beam-campus/bc-gitops-demo-repo)
3. Provides a real-time dashboard showing managed applications

## Quick Start

```bash
# Clone the repo
git clone https://github.com/beam-campus/bc-gitops-demo-web.git
cd bc-gitops-demo-web

# Install dependencies
mix deps.get

# Start the server
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000) to see the dashboard.

## Dashboard Features

- **Status Bar**: Shows sync status, last commit, app count, healthy count
- **Managed Applications**: Lists all apps deployed via bc_gitops with their status
- **Event Log**: Real-time stream of bc_gitops telemetry events
- **Sync Button**: Trigger manual reconciliation

## How It Works

1. On startup, bc_gitops clones [bc-gitops-demo-repo](https://github.com/beam-campus/bc-gitops-demo-repo)
2. It watches for changes every 30 seconds (configurable)
3. When you add/modify/remove `app.config` files in the repo, bc_gitops:
   - **Deploys** new applications
   - **Upgrades** applications with version changes (hot code reload!)
   - **Removes** applications that are deleted from the repo
4. The dashboard updates in real-time via Phoenix PubSub

## Configuration

Edit `config/config.exs` to change bc_gitops settings:

```elixir
config :bc_gitops,
  repo_url: "https://github.com/beam-campus/bc-gitops-demo-repo.git",
  branch: "master",
  reconcile_interval: 30_000,
  runtime_module: :bc_gitops_runtime_default
```

## Demo Flow

1. Start this app: `mix phx.server`
2. Open the dashboard at http://localhost:4000
3. Clone [bc-gitops-demo-repo](https://github.com/beam-campus/bc-gitops-demo-repo)
4. Add an `app.config` file (e.g., for demo_counter)
5. Commit and push
6. Watch the dashboard update as bc_gitops deploys the app!

## Related Repositories

- [bc-gitops](https://github.com/beam-campus/bc-gitops) - The GitOps library
- [bc-gitops-demo-repo](https://github.com/beam-campus/bc-gitops-demo-repo) - GitOps specs
- [bc-gitops-demo-counter](https://github.com/beam-campus/bc-gitops-demo-counter) - Erlang counter app
- [bc-gitops-demo-tui](https://github.com/beam-campus/bc-gitops-demo-tui) - Rust TUI app

## License

MIT
