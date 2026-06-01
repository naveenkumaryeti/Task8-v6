#!/usr/bin/env bash
# ============================================================
# cleanup.sh  —  COMPLETE TEARDOWN
#
# Removes EVERY resource created by all project scripts:
#
#   Phase 1  — Kubernetes app resources     (production namespace)
#   Phase 2  — Kubernetes Vault resources   (vault namespace)
#   Phase 3  — NGINX Ingress Controller     (ingress-nginx namespace)
#   Phase 4  — cert-manager                 (cert-manager namespace)
#   Phase 5  — HashiCorp Vault Helm release
#   Phase 6  — Cluster-scoped resources     (ClusterIssuer, ClusterRoleBinding)
#   Phase 7  — Temp files on disk           (/tmp/.vault-env, port-forward logs)
#   Phase 8  — Google Artifact Registry     (Docker image repository)
#   Phase 9  — GKE Cluster                  (deletes all k8s resources inside it)
#
# Usage:
#   bash scripts/cleanup.sh                   # Interactive — prompts before each phase
#   bash scripts/cleanup.sh --force           # Skip all confirmation prompts
#   bash scripts/cleanup.sh --skip-gke        # Everything EXCEPT the GKE cluster
#   bash scripts/cleanup.sh --skip-gar        # Everything EXCEPT Artifact Registry
#   bash scripts/cleanup.sh --force --skip-gke --skip-gar  # K8s resources only
#
# Environment variable overrides (all have defaults):
#   GCP_PROJECT_ID  — GCP project ID          (default: naveen-devops-cicd)
#   GCP_REGION      — GCP region              (default: asia-south1)
#   GCP_ZONE        — GCP zone                (default: asia-south1-a)
#   GKE_CLUSTER_NAME— GKE cluster name        (default: gke-microservices)
#   GAR_REPO_NAME   — Artifact Registry repo  (default: prod-repo)
#   K8S_NAMESPACE   — App namespace           (default: production)
#   VAULT_NAMESPACE — Vault namespace         (default: vault)
#
# What this script does NOT touch:
#   - Your gcloud authentication / project config
#   - GCP APIs that were enabled (container, artifactregistry, etc.)
#   - Any resources outside this project
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ── Configuration (all overridable via environment variables) ──────────────────
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
REGION="${GCP_REGION:-asia-south1}"
ZONE="${GCP_ZONE:-asia-south1-a}"
CLUSTER_NAME="${GKE_CLUSTER_NAME:-gke-microservices}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
APP_NS="${K8S_NAMESPACE:-production}"
VAULT_NS="${VAULT_NAMESPACE:-vault}"

# ── Flag parsing ───────────────────────────────────────────────────────────────
FORCE=false
SKIP_GKE=false
SKIP_GAR=false

for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=true    ;;
    --skip-gke) SKIP_GKE=true ;;
    --skip-gar) SKIP_GAR=true ;;
    --help|-h)
      sed -n '2,40p' "$0" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
  esac
done

# ── Colors and logging helpers ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓  $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠  $*${NC}"; }
info()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] ➜  $*${NC}"; }
title() { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"; \
          echo -e "${CYAN}${BOLD}  $*${NC}"; \
          echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"; }
deleted() { echo -e "${RED}[$(date +'%H:%M:%S')] 🗑  $*${NC}"; }

# ── ask(): prompt unless --force was passed ────────────────────────────────────
# Usage: ask "Delete the XYZ namespace?" || continue
ask() {
  local prompt="$1"
  if [ "$FORCE" = true ]; then
    warn "$prompt → auto-confirmed (--force)"
    return 0
  fi
  echo -e "${YELLOW}  $prompt${NC}"
  read -rp "  Type 'yes' to confirm, anything else to skip: " REPLY
  [ "$REPLY" = "yes" ]
}

# ── safe_delete(): kubectl delete that never fails the script ──────────────────
# Usage: safe_delete "resource description" kubectl delete ...
safe_delete() {
  local desc="$1"; shift
  if "$@" --ignore-not-found 2>/dev/null; then
    deleted "$desc"
  else
    warn "Could not delete $desc (may not exist — skipping)"
  fi
}

# ── ns_exists(): check if a namespace exists ──────────────────────────────────
ns_exists() {
  kubectl get namespace "$1" --no-headers 2>/dev/null | grep -q "^$1" || return 1
}

# ── cluster_reachable(): guard all kubectl calls ──────────────────────────────
cluster_reachable() {
  kubectl cluster-info --request-timeout=5s >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT: Show what will be deleted
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║         COMPLETE PROJECT TEARDOWN SCRIPT             ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Project ID    : ${BOLD}${PROJECT_ID}${NC}"
echo -e "  Region/Zone   : ${BOLD}${REGION} / ${ZONE}${NC}"
echo -e "  GKE Cluster   : ${BOLD}${CLUSTER_NAME}${NC}  $([ "$SKIP_GKE" = true ] && echo -e "${YELLOW}[WILL BE SKIPPED]${NC}" || echo -e "${RED}[WILL BE DELETED]${NC}")"
echo -e "  GAR Repo      : ${BOLD}${REPO_NAME}${NC}      $([ "$SKIP_GAR" = true ] && echo -e "${YELLOW}[WILL BE SKIPPED]${NC}" || echo -e "${RED}[WILL BE DELETED]${NC}")"
echo -e "  App Namespace : ${BOLD}${APP_NS}${NC}"
echo -e "  Vault Namespace: ${BOLD}${VAULT_NS}${NC}"
echo ""
echo -e "${YELLOW}  Phases that will run:${NC}"
echo -e "    Phase 1  — Kubernetes app resources     (namespace: ${APP_NS})"
echo -e "    Phase 2  — Kubernetes Vault resources   (namespace: ${VAULT_NS})"
echo -e "    Phase 3  — NGINX Ingress Controller     (namespace: ingress-nginx)"
echo -e "    Phase 4  — cert-manager                 (namespace: cert-manager)"
echo -e "    Phase 5  — Helm releases (vault)"
echo -e "    Phase 6  — Cluster-scoped resources     (ClusterIssuer, ClusterRoleBinding)"
echo -e "    Phase 7  — Local temp files             (/tmp/.vault-env, port-forward logs)"
[ "$SKIP_GAR" = false ] && echo -e "    Phase 8  — Google Artifact Registry     (${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME})"
[ "$SKIP_GKE" = false ] && echo -e "    Phase 9  — GKE Cluster                  (${CLUSTER_NAME})"
echo ""

if [ "$FORCE" = false ]; then
  echo -e "${RED}${BOLD}  ⚠️  This will permanently destroy all listed resources.${NC}"
  read -rp "  Type 'yes' to begin teardown, anything else to abort: " MASTER_CONFIRM
  [ "$MASTER_CONFIRM" = "yes" ] || { echo "  Aborted. Nothing was deleted."; exit 0; }
fi

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Kubernetes application resources  (namespace: production)
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 1 — Application Resources (namespace: ${APP_NS})"

if ! cluster_reachable; then
  warn "Cannot reach Kubernetes cluster — skipping Phases 1-6."
  warn "If the cluster exists, run: gcloud container clusters get-credentials ${CLUSTER_NAME} --zone=${ZONE}"
  CLUSTER_REACHABLE=false
else
  CLUSTER_REACHABLE=true
fi

if [ "$CLUSTER_REACHABLE" = true ] && ns_exists "$APP_NS"; then

  ask "Delete all application resources in namespace '${APP_NS}'?" && {

    # ── Horizontal Pod Autoscalers ─────────────────────────────────────────────
    info "Removing HPAs..."
    safe_delete "HPA: backend-hpa"  kubectl delete hpa backend-hpa  -n "$APP_NS"
    safe_delete "HPA: frontend-hpa" kubectl delete hpa frontend-hpa -n "$APP_NS"
    # Catch any other HPAs we may have missed
    kubectl delete hpa --all -n "$APP_NS" --ignore-not-found 2>/dev/null || true

    # ── PodDisruptionBudgets ───────────────────────────────────────────────────
    info "Removing PodDisruptionBudgets..."
    kubectl delete pdb --all -n "$APP_NS" --ignore-not-found 2>/dev/null || true
    log "PodDisruptionBudgets removed"

    # ── Ingress ────────────────────────────────────────────────────────────────
    info "Removing Ingress..."
    safe_delete "Ingress: app-ingress" kubectl delete ingress app-ingress -n "$APP_NS"

    # ── Services ───────────────────────────────────────────────────────────────
    info "Removing Services..."
    safe_delete "Service: frontend-service" kubectl delete service frontend-service -n "$APP_NS"
    safe_delete "Service: backend-service"  kubectl delete service backend-service  -n "$APP_NS"
    safe_delete "Service: mysql-service"    kubectl delete service mysql-service    -n "$APP_NS"

    # ── Deployments ────────────────────────────────────────────────────────────
    info "Removing Deployments..."
    safe_delete "Deployment: frontend" kubectl delete deployment frontend -n "$APP_NS"
    safe_delete "Deployment: backend"  kubectl delete deployment backend  -n "$APP_NS"

    # ── StatefulSet ────────────────────────────────────────────────────────────
    info "Removing MySQL StatefulSet..."
    # Scale to 0 first so the pod shuts down cleanly before the PVC is touched
    kubectl scale statefulset mysql --replicas=0 -n "$APP_NS" 2>/dev/null || true
    safe_delete "StatefulSet: mysql" kubectl delete statefulset mysql -n "$APP_NS"

    # ── ConfigMaps ─────────────────────────────────────────────────────────────
    info "Removing ConfigMaps..."
    safe_delete "ConfigMap: app-config"         kubectl delete configmap app-config         -n "$APP_NS"
    safe_delete "ConfigMap: mysql-config"        kubectl delete configmap mysql-config        -n "$APP_NS"
    safe_delete "ConfigMap: nginx-config"        kubectl delete configmap nginx-config        -n "$APP_NS"
    safe_delete "ConfigMap: vault-auth-config"   kubectl delete configmap vault-auth-config   -n "$APP_NS"
    safe_delete "ConfigMap: vault-secret-paths"  kubectl delete configmap vault-secret-paths  -n "$APP_NS"

    # ── Secrets ────────────────────────────────────────────────────────────────
    info "Removing Secrets..."
    safe_delete "Secret: app-tls-cert (TLS)"       kubectl delete secret app-tls-cert       -n "$APP_NS"
    safe_delete "Secret: vault-auth-sa-token"       kubectl delete secret vault-auth-sa-token -n "$APP_NS"
    # Remove any cert-manager managed secrets (letsencrypt account keys)
    kubectl delete secret letsencrypt-prod-account-key    -n "$APP_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete secret letsencrypt-staging-account-key -n "$APP_NS" --ignore-not-found 2>/dev/null || true

    # ── ServiceAccounts ────────────────────────────────────────────────────────
    info "Removing ServiceAccounts..."
    safe_delete "ServiceAccount: vault-auth-sa" kubectl delete serviceaccount vault-auth-sa -n "$APP_NS"

    # ── PersistentVolumeClaim (MySQL data) ─────────────────────────────────────
    # Listed separately because it contains persistent data
    if ask "  ⚠️  Delete MySQL PVC 'mysql-pvc' in '${APP_NS}'? (ALL DATABASE DATA WILL BE LOST)"; then
      safe_delete "PVC: mysql-pvc" kubectl delete pvc mysql-pvc -n "$APP_NS"
      log "MySQL PVC deleted — database data is gone"
    else
      warn "MySQL PVC retained. To delete manually: kubectl delete pvc mysql-pvc -n ${APP_NS}"
    fi

    # ── cert-manager Certificate resources ────────────────────────────────────
    info "Removing cert-manager Certificate resources..."
    kubectl delete certificate     --all -n "$APP_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete certificaterequest --all -n "$APP_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete order           --all -n "$APP_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete challenge       --all -n "$APP_NS" --ignore-not-found 2>/dev/null || true
    log "cert-manager Certificate resources removed"

    # ── Namespace itself ───────────────────────────────────────────────────────
    if ask "  Delete the namespace '${APP_NS}' itself?"; then
      kubectl delete namespace "$APP_NS" --ignore-not-found 2>/dev/null || true
      log "Namespace '${APP_NS}' deleted"
    else
      warn "Namespace '${APP_NS}' retained"
    fi
  }

elif [ "$CLUSTER_REACHABLE" = true ]; then
  warn "Namespace '${APP_NS}' does not exist — skipping Phase 1"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Vault resources  (namespace: vault)
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 2 — Vault Resources (namespace: ${VAULT_NS})"

if [ "$CLUSTER_REACHABLE" = true ] && ns_exists "$VAULT_NS"; then

  ask "Delete all Vault resources in namespace '${VAULT_NS}'?" && {

    # ── Uninstall Vault Helm release ───────────────────────────────────────────
    info "Uninstalling Vault Helm release..."
    if helm status vault -n "$VAULT_NS" >/dev/null 2>&1; then
      helm uninstall vault -n "$VAULT_NS" 2>/dev/null && deleted "Helm release: vault" || warn "helm uninstall vault failed (may already be gone)"
    else
      warn "Helm release 'vault' not found — skipping helm uninstall"
    fi

    # ── Vault data PVC (Vault stores its encrypted data here) ─────────────────
    info "Removing Vault data PVC..."
    kubectl delete pvc --all -n "$VAULT_NS" --ignore-not-found 2>/dev/null || true
    log "Vault PVCs removed"

    # ── Any lingering Vault pods, services, configmaps ────────────────────────
    info "Cleaning up remaining Vault namespace resources..."
    kubectl delete all --all -n "$VAULT_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete serviceaccount --all -n "$VAULT_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete configmap      --all -n "$VAULT_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete secret         --all -n "$VAULT_NS" --ignore-not-found 2>/dev/null || true
    log "Vault namespace resources removed"

    # ── Vault namespace ────────────────────────────────────────────────────────
    kubectl delete namespace "$VAULT_NS" --ignore-not-found 2>/dev/null || true
    log "Namespace '${VAULT_NS}' deleted"
  }

elif [ "$CLUSTER_REACHABLE" = true ]; then
  warn "Namespace '${VAULT_NS}' does not exist — skipping Phase 2"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — NGINX Ingress Controller  (namespace: ingress-nginx)
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 3 — NGINX Ingress Controller (namespace: ingress-nginx)"

if [ "$CLUSTER_REACHABLE" = true ] && ns_exists "ingress-nginx"; then

  ask "Delete the NGINX Ingress Controller (namespace: ingress-nginx)?" && {

    info "Removing NGINX Ingress Controller resources..."

    # Delete via the same manifest that installed it
    kubectl delete \
      -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml \
      --ignore-not-found 2>/dev/null \
    && log "NGINX Ingress manifests deleted" \
    || warn "Could not delete via manifest — falling back to namespace delete"

    # Remove ValidatingWebhookConfiguration that the ingress controller installs
    kubectl delete validatingwebhookconfigurations \
      ingress-nginx-admission --ignore-not-found 2>/dev/null || true

    # Force-delete the namespace (webhook can block namespace termination)
    kubectl delete namespace ingress-nginx --ignore-not-found 2>/dev/null || true
    log "Namespace 'ingress-nginx' deleted"
  }

elif [ "$CLUSTER_REACHABLE" = true ]; then
  warn "Namespace 'ingress-nginx' does not exist — skipping Phase 3"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — cert-manager  (namespace: cert-manager)
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 4 — cert-manager (namespace: cert-manager)"

if [ "$CLUSTER_REACHABLE" = true ] && ns_exists "cert-manager"; then

  ask "Delete cert-manager and all its resources (namespace: cert-manager)?" && {

    info "Removing cert-manager CRDs and resources..."

    # Delete via the same manifest that installed it
    kubectl delete \
      -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml \
      --ignore-not-found 2>/dev/null \
    && log "cert-manager manifests deleted" \
    || warn "Could not delete via manifest URL — falling back to namespace delete"

    # Remove MutatingWebhookConfiguration and ValidatingWebhookConfiguration
    # These are cluster-scoped and survive namespace deletion
    kubectl delete mutatingwebhookconfigurations \
      cert-manager-webhook --ignore-not-found 2>/dev/null || true
    kubectl delete validatingwebhookconfigurations \
      cert-manager-webhook --ignore-not-found 2>/dev/null || true

    # Remove cert-manager CRDs (cluster-scoped)
    info "Removing cert-manager CRDs..."
    for crd in \
      certificaterequests.cert-manager.io \
      certificates.cert-manager.io \
      challenges.acme.cert-manager.io \
      clusterissuers.cert-manager.io \
      issuers.cert-manager.io \
      orders.acme.cert-manager.io; do
      kubectl delete crd "$crd" --ignore-not-found 2>/dev/null && deleted "CRD: $crd" || true
    done

    # Namespace
    kubectl delete namespace cert-manager --ignore-not-found 2>/dev/null || true
    log "Namespace 'cert-manager' deleted"
  }

elif [ "$CLUSTER_REACHABLE" = true ]; then
  warn "Namespace 'cert-manager' does not exist — skipping Phase 4"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Remaining Helm releases (catch any not removed in Phase 2)
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 5 — Remaining Helm Releases"

if [ "$CLUSTER_REACHABLE" = true ]; then

  info "Checking for any remaining project Helm releases..."

  for release_and_ns in "vault:${VAULT_NS}" "vault:vault"; do
    RELEASE="${release_and_ns%%:*}"
    NS="${release_and_ns##*:}"
    if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
      ask "Delete Helm release '${RELEASE}' in namespace '${NS}'?" && {
        helm uninstall "$RELEASE" -n "$NS" 2>/dev/null && deleted "Helm release: ${RELEASE} (ns: ${NS})" || true
      }
    fi
  done

  log "Helm release check complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Cluster-scoped resources
# These survive namespace deletion and must be removed explicitly.
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 6 — Cluster-Scoped Resources"

if [ "$CLUSTER_REACHABLE" = true ]; then

  ask "Delete cluster-scoped resources (ClusterIssuer, ClusterRoleBinding, CRDs)?" && {

    # ── ClusterIssuers (from cert-manager/cluster-issuer.yaml) ────────────────
    info "Removing ClusterIssuers..."
    kubectl delete clusterissuer letsencrypt-prod    --ignore-not-found 2>/dev/null && deleted "ClusterIssuer: letsencrypt-prod"    || true
    kubectl delete clusterissuer letsencrypt-staging --ignore-not-found 2>/dev/null && deleted "ClusterIssuer: letsencrypt-staging" || true

    # ── ClusterRoleBinding (from vault/vault-auth.yaml) ───────────────────────
    # vault-auth-sa is bound to system:auth-delegator at CLUSTER scope
    info "Removing ClusterRoleBindings created by vault-auth.yaml..."
    kubectl delete clusterrolebinding vault-auth-sa-binding --ignore-not-found 2>/dev/null && deleted "ClusterRoleBinding: vault-auth-sa-binding" || true
    # Also remove any NGINX Ingress cluster-scoped RBAC
    kubectl delete clusterrolebinding ingress-nginx         --ignore-not-found 2>/dev/null || true
    kubectl delete clusterrole        ingress-nginx         --ignore-not-found 2>/dev/null || true

    # ── IngressClass (installed by NGINX Ingress Controller) ──────────────────
    info "Removing IngressClass..."
    kubectl delete ingressclass nginx --ignore-not-found 2>/dev/null && deleted "IngressClass: nginx" || true

    # ── Vault-related CRDs (if Vault CRDs were applied) ───────────────────────
    info "Removing any Vault CRDs..."
    kubectl get crd 2>/dev/null | grep "vault.banzaicloud.com\|vault.hashicorp.com" \
      | awk '{print $1}' \
      | xargs -r kubectl delete crd --ignore-not-found 2>/dev/null \
    && log "Vault CRDs removed" || warn "No Vault CRDs found"

    log "Cluster-scoped resources removed"
  }
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Local temp files written by the scripts
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 7 — Local Temp Files"

ask "Delete local temp files created by deployment scripts?" && {

  # Written by deploy-vault.sh — contains Vault root token + unseal keys
  if [ -f /tmp/.vault-env ]; then
    rm -f /tmp/.vault-env
    deleted "Temp file: /tmp/.vault-env (Vault credentials)"
  else
    warn "/tmp/.vault-env not found — already gone"
  fi

  # Port-forward log files written by vault-secrets.sh, deploy-database.sh
  for f in \
    /tmp/vault-portforward.log \
    /tmp/vault-portforward-secrets.log \
    /tmp/vault-pf-db.log; do
    if [ -f "$f" ]; then
      rm -f "$f"
      deleted "Temp file: $f"
    fi
  done

  # CA cert file that vault-secrets.sh extracts from the cluster
  for f in /tmp/k8s-ca-*.crt /tmp/vault-ca-*.crt; do
    # Glob expansion — only delete if files actually exist
    ls "$f" 2>/dev/null | while read -r match; do
      rm -f "$match"
      deleted "Temp file: $match"
    done
  done

  # vault-init-keys.json — written to project root by deploy-vault.sh
  # Contains unseal keys and root token — warn before deleting
  if [ -f vault-init-keys.json ]; then
    if ask "  ⚠️  Delete vault-init-keys.json? (contains Vault unseal keys + root token — unrecoverable)"; then
      rm -f vault-init-keys.json
      deleted "Project file: vault-init-keys.json"
    else
      warn "vault-init-keys.json retained — keep it safe, do not commit to git"
    fi
  fi

  log "Temp file cleanup complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Google Artifact Registry repository
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 8 — Google Artifact Registry"

if [ "$SKIP_GAR" = true ]; then
  warn "Skipping Artifact Registry deletion (--skip-gar was passed)"
else
  if command -v gcloud >/dev/null 2>&1; then

    # Check if the repo exists before attempting deletion
    if gcloud artifacts repositories describe "$REPO_NAME" \
        --location="$REGION" \
        --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then

      ask "Delete Artifact Registry repo '${REPO_NAME}' in '${REGION}'? (ALL pushed Docker images will be lost)" && {
        gcloud artifacts repositories delete "$REPO_NAME" \
          --location="$REGION" \
          --project="$PROJECT_ID" \
          --quiet \
        && deleted "Artifact Registry repository: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}" \
        || warn "Failed to delete Artifact Registry repo — check IAM permissions"
      }

    else
      warn "Artifact Registry repo '${REPO_NAME}' not found in ${REGION} — skipping"
    fi

  else
    warn "gcloud CLI not found — cannot delete Artifact Registry repo. Delete manually in GCP Console."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — GKE Cluster
# This is the nuclear option. Deleting the cluster removes ALL Kubernetes
# resources inside it in one shot. It is intentionally the last step.
# ══════════════════════════════════════════════════════════════════════════════
title "Phase 9 — GKE Cluster"

if [ "$SKIP_GKE" = true ]; then
  warn "Skipping GKE cluster deletion (--skip-gke was passed)"
else
  if command -v gcloud >/dev/null 2>&1; then

    if gcloud container clusters describe "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --quiet 2>/dev/null; then

      echo ""
      echo -e "${RED}${BOLD}  ╔═══════════════════════════════════════════════════╗${NC}"
      echo -e "${RED}${BOLD}  ║  ⚠️  DELETING THE GKE CLUSTER IS IRREVERSIBLE    ║${NC}"
      echo -e "${RED}${BOLD}  ║  All node VMs, volumes, and workloads will be     ║${NC}"
      echo -e "${RED}${BOLD}  ║  permanently destroyed.                           ║${NC}"
      echo -e "${RED}${BOLD}  ╚═══════════════════════════════════════════════════╝${NC}"
      echo ""

      ask "Type 'yes' to permanently DELETE the GKE cluster '${CLUSTER_NAME}' in zone '${ZONE}'?" && {
        info "Deleting GKE cluster '${CLUSTER_NAME}'... (this takes 3-5 minutes)"
        gcloud container clusters delete "$CLUSTER_NAME" \
          --zone="$ZONE" \
          --project="$PROJECT_ID" \
          --quiet \
        && deleted "GKE Cluster: ${CLUSTER_NAME} (zone: ${ZONE})" \
        || warn "GKE cluster deletion failed — check GCP Console for status"

        # Clean up any residual firewall rules GKE left behind
        info "Removing GKE-created firewall rules..."
        gcloud compute firewall-rules list \
          --filter="name~gke-${CLUSTER_NAME}" \
          --format="value(name)" \
          --project="$PROJECT_ID" 2>/dev/null \
        | while read -r rule; do
            gcloud compute firewall-rules delete "$rule" \
              --project="$PROJECT_ID" \
              --quiet 2>/dev/null \
            && deleted "Firewall rule: $rule" || true
          done

        # Clean up auto-provisioned GKE node disks (orphaned after cluster delete)
        info "Checking for orphaned persistent disks in zone ${ZONE}..."
        gcloud compute disks list \
          --filter="zone:${ZONE} AND name~gke-${CLUSTER_NAME}" \
          --format="value(name)" \
          --project="$PROJECT_ID" 2>/dev/null \
        | while read -r disk; do
            warn "Orphaned disk found: $disk"
            if ask "    Delete orphaned disk '${disk}'?"; then
              gcloud compute disks delete "$disk" \
                --zone="$ZONE" \
                --project="$PROJECT_ID" \
                --quiet 2>/dev/null \
              && deleted "Orphaned disk: $disk" || true
            fi
          done
      }

    else
      warn "GKE cluster '${CLUSTER_NAME}' not found in zone '${ZONE}' — skipping"
    fi

  else
    warn "gcloud CLI not found — cannot delete GKE cluster. Delete manually in GCP Console."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║              CLEANUP COMPLETE                        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}What was cleaned up (if confirmed at each prompt):${NC}"
echo -e "  ✓ production namespace + all app workloads + MySQL PVC"
echo -e "  ✓ vault namespace + Helm release + Vault data PVC"
echo -e "  ✓ ingress-nginx namespace + LoadBalancer service"
echo -e "  ✓ cert-manager namespace + CRDs + webhook configurations"
echo -e "  ✓ Cluster-scoped RBAC (ClusterRoleBinding, IngressClass)"
echo -e "  ✓ cert-manager ClusterIssuers (letsencrypt-prod/staging)"
echo -e "  ✓ Local temp files (/tmp/.vault-env, port-forward logs)"
[ "$SKIP_GAR" = false ] && echo -e "  ✓ Artifact Registry repository + all Docker images"
[ "$SKIP_GKE" = false ] && echo -e "  ✓ GKE cluster + node VMs + GKE firewall rules"
echo ""
echo -e "  ${YELLOW}What this script did NOT remove:${NC}"
echo -e "  • GCP APIs that were enabled (container, artifactregistry, etc.)"
echo -e "  • Your gcloud authentication or project configuration"
echo -e "  • Any GCP resources outside this project"
echo -e "  • GitHub Actions secrets"
[ "$SKIP_GKE" = true ]  && echo -e "  • GKE Cluster (--skip-gke was passed)"
[ "$SKIP_GAR" = true ]  && echo -e "  • Artifact Registry repo (--skip-gar was passed)"
echo ""