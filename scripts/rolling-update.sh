#!/usr/bin/env bash
# ============================================================
# rolling-update.sh
#
# Triggers a zero-downtime rolling update for a specific component.
# Updates the image and waits for the rollout to complete.
# Automatically rolls back if rollout fails.
#
# Usage:
#   bash scripts/rolling-update.sh <component> <version>
#   bash scripts/rolling-update.sh backend 1.2.0
#   bash scripts/rolling-update.sh frontend 1.2.0
#   bash scripts/rolling-update.sh all 1.2.0
# ============================================================

set -euo pipefail

COMPONENT="${1:-all}"
VERSION="${2:-${APP_VERSION:-1.0.0}}"
NAMESPACE="${K8S_NAMESPACE:-production}"
PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project-id}"
REGION="${GCP_REGION:-asia-south1}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

# ── Rolling update function ───────────────────────────────────────────────────
perform_rolling_update() {
  local deployment="$1"
  local container="$2"
  local image_name="$3"

  log "Rolling update: $deployment → ${REGISTRY}/${image_name}:${VERSION}"

  # Annotate deployment for audit trail (shows in kubectl rollout history)
  kubectl annotate deployment "$deployment" \
    kubernetes.io/change-cause="Rolling update to v${VERSION} at $(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    -n "$NAMESPACE" --overwrite

  # Set new image — Kubernetes starts rolling update immediately
  kubectl set image deployment/"$deployment" \
    "${container}=${REGISTRY}/${image_name}:${VERSION}" \
    -n "$NAMESPACE"

  # Wait for rollout to complete
  log "Waiting for $deployment rollout to complete..."
  if kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=300s; then
    log "$deployment update to v${VERSION} successful!"
  else
    warn "Rollout failed! Initiating automatic rollback for $deployment..."
    kubectl rollout undo deployment/"$deployment" -n "$NAMESPACE"
    kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=120s
    fail "Rollout failed — rolled back to previous version. Check logs: kubectl logs -l app=$deployment -n $NAMESPACE"
  fi
}

# ── Execute update ────────────────────────────────────────────────────────────
case "$COMPONENT" in
  frontend)
    perform_rolling_update "frontend" "nginx" "frontend"
    ;;
  backend)
    perform_rolling_update "backend" "backend" "backend"
    ;;
  all)
    log "Updating all components to v${VERSION}..."
    perform_rolling_update "frontend" "nginx"    "frontend"
    perform_rolling_update "backend"  "backend"  "backend"
    ;;
  *)
    fail "Unknown component: $COMPONENT. Use: frontend | backend | all"
    ;;
esac

# ── Post-update verification ──────────────────────────────────────────────────
log "Post-update pod status:"
kubectl get pods -n "$NAMESPACE" -l "app in (frontend,backend)" -o wide

log "Rollout history:"
kubectl rollout history deployment/frontend -n "$NAMESPACE" 2>/dev/null | tail -5
kubectl rollout history deployment/backend  -n "$NAMESPACE" 2>/dev/null | tail -5

log "✅ Rolling update to v${VERSION} complete!"
