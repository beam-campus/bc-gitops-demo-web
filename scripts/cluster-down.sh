#!/bin/bash
# Stop the demo_web cluster
#
# Usage:
#   ./scripts/cluster-down.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Stopping cluster..."
docker compose down

echo "==> Cluster stopped"
