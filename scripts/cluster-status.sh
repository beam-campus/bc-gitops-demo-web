#!/bin/bash
# Check cluster status
#
# Usage:
#   ./scripts/cluster-status.sh

set -euo pipefail

echo "==> Docker containers:"
docker compose ps 2>/dev/null || echo "  No containers running"
echo ""

echo "==> Node health:"
echo ""
for port in 4001 4002 4003; do
    echo "Node at :${port}:"
    health=$(curl -s "http://localhost:${port}/health" 2>/dev/null)
    if [ -n "$health" ]; then
        echo "$health" | jq -r '"  Status: \(.status), Node: \(.node), Cluster: \(.cluster_nodes | length) peers"' 2>/dev/null || echo "  $health"
    else
        echo "  Not responding"
    fi
    echo ""
done
