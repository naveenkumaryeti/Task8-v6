#!/usr/bin/env bash
# ============================================================
# build-images.sh
#
# Builds Docker images for frontend and backend.
# Uses BuildKit for faster parallel builds and cache efficiency.
#
# Usage:
#   bash scripts/build-images.sh [VERSION]
#   bash scripts/build-images.sh 1.2.0
# ============================================================

set -euo pipefail

VERSION="${1:-${APP_VERSION:-1.0.0}}"
PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project-id}"
REGION="${GCP_REGION:-asia-south1}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

# Enable BuildKit for multi-stage build optimizations
export DOCKER_BUILDKIT=1

log "Building images for version: $VERSION"
log "Registry: $REGISTRY"

# ── Build Frontend ────────────────────────────────────────────────────────────
log "Building frontend image..."
docker build \
  --file frontend/Dockerfile \
  --tag "frontend:${VERSION}" \
  --tag "frontend:latest" \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VERSION="$VERSION" \
  --progress=plain \
  ./frontend

log "Frontend image built: frontend:${VERSION}"

# ── Build Backend ─────────────────────────────────────────────────────────────
log "Building backend image..."
docker build \
  --file backend/Dockerfile \
  --tag "backend:${VERSION}" \
  --tag "backend:latest" \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VERSION="$VERSION" \
  --progress=plain \
  ./backend

log "Backend image built: backend:${VERSION}"

# ── Display image sizes ───────────────────────────────────────────────────────
log "Built images:"
docker images | grep -E "^(frontend|backend)" | awk '{printf "  %-20s %-15s %s\n", $1, $2, $7}'

log "✅ Docker builds complete!"
log "Next step: bash scripts/push-images.sh $VERSION"
