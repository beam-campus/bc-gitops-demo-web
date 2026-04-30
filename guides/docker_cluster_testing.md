# Docker Cluster Testing Guide

This guide explains how to test bc_gitops isolated VM deployment using a 3-node Docker cluster.

## Overview

The Docker setup creates 3 demo_web nodes that auto-cluster via Erlang distribution:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Network: macula_mesh                   │
├───────────────────┬───────────────────┬────────────────────────┤
│   Container 1     │   Container 2     │   Container 3          │
│   demo_web_node1  │   demo_web_node2  │   demo_web_node3       │
│   demo1@node1     │   demo2@node2     │   demo3@node3          │
│                   │                   │                        │
│   Port 4001       │   Port 4002       │   Port 4003            │
│                   │                   │                        │
│   ↓ can spawn     │   ↓ can spawn     │   ↓ can spawn          │
│   isolated VMs    │   isolated VMs    │   isolated VMs         │
└───────────────────┴───────────────────┴────────────────────────┘
        ↕ Erlang Distribution (cookie: macula_mesh_dev) ↕
```

## Quick Start

```bash
# Build the Docker image (includes bc_gitops)
./scripts/build-docker.sh

# Start the 3-node cluster
./scripts/cluster-up.sh

# Check cluster status
./scripts/cluster-status.sh

# View logs
docker compose logs -f

# Stop the cluster
./scripts/cluster-down.sh
```

## Ports

| Node | HTTP | EPMD | Distribution |
|------|------|------|--------------|
| node1 | 4001 | 4369 | 9100-9105 |
| node2 | 4002 | 4370 | 9110-9115 |
| node3 | 4003 | 4371 | 9120-9125 |

## Health Check Endpoint

Each node exposes `/health` endpoint:

```bash
curl http://localhost:4001/health
```

Response:
```json
{
  "status": "ok",
  "node": "demo1@node1",
  "cluster_nodes": ["demo2@node2", "demo3@node3"],
  "uptime_seconds": 42
}
```

## Testing Isolated VM Deployment

Once the cluster is running, you can test isolated VM deployment:

1. **Access any node's dashboard**: http://localhost:4001

2. **Configure an app with `isolation: vm`** in the gitops repo:
   ```erlang
   #{
       name => demo_uptime,
       version => <<"0.3.0">>,
       source => #{type => hex},
       isolation => vm,  %% Run in isolated VM
       vm_config => #{
           memory_limit => 256,
           scheduler_limit => 1
       },
       env => #{http_port => 8083}
   }.
   ```

3. **Trigger reconciliation** via the GitOps UI

4. **Observe**:
   - The guest app spawns in its own BEAM VM
   - It joins the cluster (visible in Node.list())
   - PubSub messages flow between guest and host

## Cluster Communication

Nodes communicate via:

1. **EPMD** (Erlang Port Mapper Daemon): Port 4369
2. **Distribution ports**: 9100-9125 range
3. **Shared cookie**: `macula_mesh_dev`

All nodes use the same cookie and can connect via the Docker network.

## Troubleshooting

### Nodes not clustering

Check if EPMD is running and ports are accessible:

```bash
docker exec demo_web_node1 epmd -names
```

### Build fails

Ensure bc_gitops exists at `../bc-gitops` relative to this directory:

```
beam-campus/
├── bc-gitops/           # Required
├── bc-gitops-demo-web/  # This project
└── bc-gitops-demo-repo/ # GitOps repo (optional for testing)
```

### Container crashes

Check logs:
```bash
docker compose logs node1
```

Common issues:
- Missing SECRET_KEY_BASE
- Port conflicts with local services
- Insufficient memory

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| RELEASE_NODE | Erlang node name | demo{N}@node{N} |
| RELEASE_COOKIE | Cluster cookie | macula_mesh_dev |
| PORT | HTTP port | 4000 |
| SECRET_KEY_BASE | Phoenix secret | (required) |
| CLUSTER_NODES | Comma-separated node list | (all 3 nodes) |
| BC_GITOPS_REPO_PATH | Path to gitops repo | /app/gitops-repo |

## Volume Mounts

| Volume | Purpose |
|--------|---------|
| node{N}_data | Node-specific persistent data |
| gitops_repo | Shared GitOps repository (for testing) |

In production, each node would have its own gitops repo clone.

## Next Steps

After verifying the cluster works:

1. **Test with real guest apps**: Configure demo_uptime with `isolation: vm`
2. **Test crash isolation**: Kill a guest VM, verify host continues
3. **Test PubSub across nodes**: Broadcast from guest, receive on different host
4. **Scale testing**: Add more nodes or more guest apps

## Related Documentation

- [bc_gitops Isolated VM Deployment Guide](../../bc-gitops/guides/isolated_vm_deployment.md)
- [bc_gitops Architecture](../../bc-gitops/assets/isolated_vm_architecture.svg)
