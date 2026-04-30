#!/bin/bash
# Build Docker image for demo_web with bc_gitops and macula
#
# This script handles the Docker build context by temporarily copying
# dependencies into the build context (Docker can't access files outside
# the build context).
#
# Usage:
#   ./scripts/build-docker.sh [tag]
#
# Examples:
#   ./scripts/build-docker.sh              # Builds demo-web:latest
#   ./scripts/build-docker.sh v0.1.0       # Builds demo-web:v0.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BC_GITOPS_DIR="$(dirname "$PROJECT_DIR")/bc-gitops"
MACULA_DIR="$(dirname "$(dirname "$PROJECT_DIR")")/macula-io/macula"

TAG="${1:-latest}"
IMAGE_NAME="demo-web:${TAG}"

echo "==> Building Docker image: ${IMAGE_NAME}"
echo "    Project dir: ${PROJECT_DIR}"
echo "    bc_gitops dir: ${BC_GITOPS_DIR}"
echo "    macula dir: ${MACULA_DIR}"

# Verify bc_gitops exists
if [ ! -d "$BC_GITOPS_DIR" ]; then
    echo "ERROR: bc_gitops not found at ${BC_GITOPS_DIR}"
    echo "       Expected directory structure:"
    echo "         beam-campus/"
    echo "           bc-gitops/"
    echo "           bc-gitops-demo-web/"
    exit 1
fi

# Verify macula exists
if [ ! -d "$MACULA_DIR" ]; then
    echo "ERROR: macula not found at ${MACULA_DIR}"
    echo "       Expected directory structure:"
    echo "         macula-io/"
    echo "           macula/"
    exit 1
fi

# Create temporary build context with dependencies
echo "==> Copying bc_gitops into build context..."
rm -rf "${PROJECT_DIR}/bc-gitops"
cp -r "$BC_GITOPS_DIR" "${PROJECT_DIR}/bc-gitops"

echo "==> Copying macula into build context..."
rm -rf "${PROJECT_DIR}/macula"
cp -r "$MACULA_DIR" "${PROJECT_DIR}/macula"

# Build the image
echo "==> Building Docker image..."
cd "$PROJECT_DIR"
docker build \
    --build-arg CACHE_BUST="$(date +%s)" \
    -t "$IMAGE_NAME" \
    -f Dockerfile \
    .

BUILD_STATUS=$?

# Clean up
echo "==> Cleaning up temporary dependency copies..."
rm -rf "${PROJECT_DIR}/bc-gitops"
rm -rf "${PROJECT_DIR}/macula"

if [ $BUILD_STATUS -eq 0 ]; then
    echo ""
    echo "==> Build successful: ${IMAGE_NAME}"
    echo ""
    echo "To run a single node:"
    echo "  docker run -p 4000:4000 -e RELEASE_NODE=demo@localhost -e RELEASE_COOKIE=dev ${IMAGE_NAME}"
    echo ""
    echo "To run a 3-node cluster (uses gossip for auto-discovery):"
    echo "  docker compose up -d"
    echo ""
else
    echo "ERROR: Build failed"
    exit 1
fi
