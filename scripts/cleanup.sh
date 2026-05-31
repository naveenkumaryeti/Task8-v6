#!/usr/bin/env bash
# ============================================================
# cleanup.sh
#
# Removes all Kubernetes resources for this application.
# Has safety prompts to prevent accidental deletion.
#
# Usage:
#   bash scripts/cleanup.sh            # Removes app (keeps namespace + PVC)
#   bash scripts/cleanup.sh --full     # Removes everything including PVC
#   bash scripts/cleanup.sh --force    # Skip confirmation prompts
# ============================================================

set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-production}"
FULL_CLEANUP=false
FORCE=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --full)  FULL_CLEANUP=true ;;
    --force) FORCE=true ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

# ── Confirmation prompt ───────────────────────────────────────────────────────
if [ "$FORCE" = false ]; then
  echo -e "${RED}⚠️  WARNING: This will delete resources in namespace '$NAMESPACE'${NC}"
  if [ "$FULL_CLEANUP" = true ]; then
    echo -e "${RED}⚠️  --full mode: This will also delete the MySQL PVC (DATA LOSS!)${NC}"
  fi
  echo ""
  read -rp "Type 'yes' to confirm: " CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }
fi

# ── Remove application resources ──────────────────────────────────────────────
log "Removing HPA..."
kubectl delete hpa --all -n "$NAMESPACE" --ignore-not-found

log "Removing PodDisruptionBudgets..."
kubectl delete pdb --all -n "$NAMESPACE" --ignore-not-found

log "Removing Ingress..."
kubectl delete ingress app-ingress -n "$NAMESPACE" --ignore-not-found

log "Removing Services..."
kubectl delete service frontend-service backend-service -n "$NAMESPACE" --ignore-not-found

log "Removing Deployments..."
kubectl delete deployment frontend backend -n "$NAMESPACE" --ignore-not-found

log "Removing MySQL StatefulSet..."
kubectl delete statefulset mysql -n "$NAMESPACE" --ignore-not-found
kubectl delete service mysql-service -n "$NAMESPACE" --ignore-not-found

log "Removing ConfigMaps..."
kubectl delete configmap app-config mysql-config nginx-config \
  vault-auth-config vault-secret-paths -n "$NAMESPACE" --ignore-not-found

# ── Full cleanup (including persistent data) ──────────────────────────────────
if [ "$FULL_CLEANUP" = true ]; then
  warn "Deleting MySQL PVC — ALL DATABASE DATA WILL BE LOST"
  kubectl delete pvc mysql-pvc -n "$NAMESPACE" --ignore-not-found

  warn "Deleting namespace '$NAMESPACE'..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found

  warn "Uninstalling Vault..."
  helm uninstall vault -n vault 2>/dev/null || true
  kubectl delete namespace vault --ignore-not-found
fi

log "✅ Cleanup complete!"
if [ "$FULL_CLEANUP" = false ]; then
  warn "Note: Namespace and MySQL PVC retained. Use --full to remove everything."
fi
