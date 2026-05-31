#!/usr/bin/env bash
# ============================================================
# push-images.sh
#
# Tags and pushes Docker images to Google Artifact Registry.
# Applies semantic versioning tags + 'latest'.
#
# Usage:
#   bash scripts/push-images.sh [VERSION]
# ============================================================

set -euo pipefail

VERSION="${1:-${APP_VERSION:-1.0.0}}"
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
REGION="${GCP_REGION:-asia-south1}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }

log "Pushing version: $VERSION to $REGISTRY"

# ── Tag and push Frontend ─────────────────────────────────────────────────────
log "Tagging frontend image..."
docker tag "frontend:${VERSION}" "${REGISTRY}/frontend:${VERSION}"
docker tag "frontend:${VERSION}" "${REGISTRY}/frontend:latest"

log "Pushing frontend:${VERSION}..."
docker push "${REGISTRY}/frontend:${VERSION}"
docker push "${REGISTRY}/frontend:latest"

# ── Tag and push Backend ──────────────────────────────────────────────────────
log "Tagging backend image..."
docker tag "backend:${VERSION}" "${REGISTRY}/backend:${VERSION}"
docker tag "backend:${VERSION}" "${REGISTRY}/backend:latest"

log "Pushing backend:${VERSION}..."
docker push "${REGISTRY}/backend:${VERSION}"
docker push "${REGISTRY}/backend:latest"

# ── Verify pushed images ──────────────────────────────────────────────────────
log "Verifying pushed images in Artifact Registry..."
gcloud artifacts docker images list "${REGISTRY}" --quiet 2>/dev/null | head -20 || true

log "✅ Images pushed successfully!"
log "Frontend: ${REGISTRY}/frontend:${VERSION}"
log "Backend:  ${REGISTRY}/backend:${VERSION}"
log "Next step: bash scripts/vault-secrets.sh"
