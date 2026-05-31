#!/usr/bin/env bash
# ============================================================
# scale-app.sh
#
# Manually scales deployments up or down.
# HPA will eventually override manual scaling — use this for
# emergency scale-up during traffic spikes before HPA kicks in.
#
# Usage:
#   bash scripts/scale-app.sh <component> <replicas>
#   bash scripts/scale-app.sh backend 5
#   bash scripts/scale-app.sh frontend 3
#   bash scripts/scale-app.sh all 5
# ============================================================

set -euo pipefail

COMPONENT="${1:-all}"
REPLICAS="${2:-3}"
NAMESPACE="${K8S_NAMESPACE:-production}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }

# Validate replica count
[[ "$REPLICAS" =~ ^[0-9]+$ ]] || fail "Replicas must be a positive integer, got: $REPLICAS"
[ "$REPLICAS" -lt 1 ] && fail "Minimum 1 replica required"
[ "$REPLICAS" -gt 20 ] && warn "Scaling to $REPLICAS replicas — ensure cluster has capacity"

scale() {
  local deployment="$1"
  local count="$2"
  log "Scaling $deployment to $count replicas..."
  kubectl scale deployment/"$deployment" --replicas="$count" -n "$NAMESPACE"
  kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout=120s
}

case "$COMPONENT" in
  backend)  scale "backend"  "$REPLICAS" ;;
  frontend) scale "frontend" "$REPLICAS" ;;
  all)
    scale "frontend" "$REPLICAS"
    scale "backend"  "$REPLICAS"
    ;;
  *)
    fail "Unknown component: $COMPONENT. Use: backend | frontend | all"
    ;;
esac

log "Current pod status:"
kubectl get pods -n "$NAMESPACE" -l "app in (frontend,backend)" \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName"

log "HPA status (HPA may override this manual scale):"
kubectl get hpa -n "$NAMESPACE"

log "✅ Scaling complete: $COMPONENT → $REPLICAS replicas"
