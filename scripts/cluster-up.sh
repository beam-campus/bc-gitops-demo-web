#!/bin/bash
# Start the 3-node demo_web cluster
#
# Usage:
#   ./scripts/cluster-up.sh
#
# This will:
#   1. Build the Docker image if it doesn't exist
#   2. Start 3 demo_web nodes
#   3. Display cluster status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Check if image exists
if ! docker image inspect demo-web:latest >/dev/null 2>&1; then
    echo "==> Docker image not found, building..."
    ./scripts/build-docker.sh
fi

echo "==> Starting 3-node cluster..."
docker compose up -d

echo ""
echo "==> Waiting for nodes to start..."
sleep 5

echo ""
echo "==> Cluster status:"
echo ""
echo "Node 1: http://localhost:4001"
curl -s http://localhost:4001/health 2>/dev/null | jq . || echo "  (starting...)"
echo ""
echo "Node 2: http://localhost:4002"
curl -s http://localhost:4002/health 2>/dev/null | jq . || echo "  (starting...)"
echo ""
echo "Node 3: http://localhost:4003"
curl -s http://localhost:4003/health 2>/dev/null | jq . || echo "  (starting...)"
echo ""
echo "==> View logs:"
echo "  docker compose logs -f"
echo ""
echo "==> Stop cluster:"
echo "  ./scripts/cluster-down.sh"
