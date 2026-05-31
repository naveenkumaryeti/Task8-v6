#!/usr/bin/env bash
# ============================================================
# scripts/deploy-k8s.sh  —  ENHANCED with Vault access checks
#
# WHAT CHANGED:
#   FIX A — Vault connectivity verified before deploying frontend/backend.
#     Backend pods use Vault Agent Injector. Without a reachable, unsealed
#     Vault, the agent init container hangs forever causing pod Pending state.
#     Script confirms Vault is up before proceeding.
#
#   FIX B — Auto-loads VAULT_TOKEN from /tmp/.vault-env if not set.
#
#   FIX C — Verifies secret/app and secret/mysql exist in Vault.
#     If not, automatically calls vault-secrets.sh to create them.
#
#   FIX D — Vault agent injector namespace label check.
#     Ensures production namespace has vault-injection=enabled label.
#
#   FIX E — cert-manager auto-install and ClusterIssuer apply.
#     (From previous enhancement — preserved unchanged.)
#
# Usage:
#   bash scripts/deploy-k8s.sh [VERSION]
# ============================================================

set -euo pipefail
IFS=$'\n\t'

VERSION="${1:-${APP_VERSION:-1.0.0}}"
NAMESPACE="${K8S_NAMESPACE:-production}"
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
REGION="${GCP_REGION:-asia-south1}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
DOMAIN="enterprise-app.gt.tc"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-8200}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_LOCAL_PORT}}"
INIT_KEYS_FILE="${VAULT_INIT_KEYS_FILE:-vault-init-keys.json}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
err()   { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; }
fail()  { err "$*"; exit 1; }
title() { echo -e "\n${CYAN}${BOLD}━━━━ $* ━━━━${NC}"; }
info()  { echo -e "${CYAN}  ➜  $*${NC}"; }

OWN_PF_PID=""
cleanup() {
  if [ -n "$OWN_PF_PID" ] && kill -0 "$OWN_PF_PID" 2>/dev/null; then
    warn "Stopping port-forward (PID $OWN_PF_PID)..."
    kill "$OWN_PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Rollout with diagnostics ───────────────────────────────────────────────────
rollout_or_debug() {
  local deployment="$1"
  local timeout="${2:-180s}"
  if ! kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout="$timeout"; then
    err "Rollout timed out for deployment/$deployment — collecting diagnostics..."
    warn "── Pod status ──"
    kubectl get pods -n "$NAMESPACE" -l "app=$deployment" -o wide || true
    warn "── Deployment describe ──"
    kubectl describe deployment/"$deployment" -n "$NAMESPACE" | tail -30 || true
    warn "── Events ──"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
    warn "── Pod logs ──"
    kubectl logs -n "$NAMESPACE" -l "app=$deployment" --tail=50 2>/dev/null || true
    warn "── Vault agent init logs (if injection failed) ──"
    kubectl logs -n "$NAMESPACE" -l "app=$deployment" -c vault-agent-init --tail=30 2>/dev/null || true
    warn "── Rolling back ──"
    kubectl rollout undo deployment/"$deployment" -n "$NAMESPACE" || true
    return 1
  fi
}

wait_deployment_or_debug() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-300s}"
  if kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"; then
    return 0
  fi

  warn "deployment/$deployment in namespace/$namespace is not ready after $timeout"
  warn "── Pod status ──"
  kubectl get pods -n "$namespace" -o wide || true
  warn "── Deployment describe ──"
  kubectl describe deployment/"$deployment" -n "$namespace" | tail -40 || true
  warn "── Recent events ──"
  kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -30 || true
  warn "── Logs ──"
  kubectl logs -n "$namespace" deployment/"$deployment" --tail=60 2>/dev/null || true
  return 1
}

log "Deploying version $VERSION → namespace: $NAMESPACE"

# ── FIX B: Auto-load VAULT_TOKEN ──────────────────────────────────────────────
title "Step 0a — Loading Vault Credentials"

if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ -f /tmp/.vault-env ]; then
    # shellcheck disable=SC1091
    source /tmp/.vault-env
    log "Loaded credentials from /tmp/.vault-env"
  elif [ -f "$INIT_KEYS_FILE" ]; then
    VAULT_TOKEN=$(python3 -c "
import json
with open('$INIT_KEYS_FILE') as f:
    d = json.load(f)
print(d.get('root_token',''))
" 2>/dev/null || true)
    [ -n "$VAULT_TOKEN" ] && log "Loaded from $INIT_KEYS_FILE" || \
      fail "Cannot load VAULT_TOKEN. Run deploy-vault.sh first."
  else
    fail "VAULT_TOKEN not set. Run deploy-vault.sh first, or: source /tmp/.vault-env"
  fi
fi

export VAULT_ADDR VAULT_TOKEN

# ── FIX A: Verify Vault connectivity ──────────────────────────────────────────
title "Step 0b — Verifying Vault Access"

port_open() {
  local port="${1:-8200}"
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" 2>/dev/null; return $?
  fi
  (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; return $?
}

check_vault() {
  port_open "$VAULT_LOCAL_PORT"
}

if ! check_vault; then
  warn "Vault not reachable at $VAULT_ADDR — starting port-forward..."

  OLD_PF=$(lsof -ti tcp:"$VAULT_LOCAL_PORT" 2>/dev/null || true)
  [ -n "$OLD_PF" ] && { kill "$OLD_PF" 2>/dev/null || true; sleep 1; }

  VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -z "$VAULT_POD" ] && fail "No Vault pod found in $VAULT_NAMESPACE. Run deploy-vault.sh first."

  kubectl port-forward --address 127.0.0.1 \
    pod/"$VAULT_POD" -n "$VAULT_NAMESPACE" \
    "${VAULT_LOCAL_PORT}:8200" >/tmp/vault-portforward.log 2>&1 &
  OWN_PF_PID=$!

  for i in $(seq 1 20); do
    sleep 2
    check_vault && { log "Port-forward ready ✓"; break; }
    [ "$i" -eq 20 ] && fail "Vault not reachable. Log: $(cat /tmp/vault-portforward.log)"
    warn "Attempt $i/20..."
  done
  VAULT_ADDR="http://127.0.0.1:${VAULT_LOCAL_PORT}"
  export VAULT_ADDR
fi

SEALED=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null \
  || echo "True")
[ "$SEALED" = "False" ] || fail "Vault is sealed! Run deploy-vault.sh (auto-unseals)."
log "Vault reachable and unsealed ✓"

# ── Ensure Vault auth Kubernetes resources exist before secret checks ─────────
title "Step 0c — Applying Vault Auth Resources"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f vault/vault-auth.yaml -n "$NAMESPACE"
log "Namespace and Vault auth applied"

# ── FIX C: Verify Vault secrets exist ─────────────────────────────────────────
title "Step 0d — Verifying Vault Secrets"

for secret_path in "secret/app" "secret/mysql"; do
  EXISTS=$(vault kv get -format=json "$secret_path" 2>/dev/null \
    | python3 -c "import sys,json; print('yes')" 2>/dev/null || echo "no")

  if [ "$EXISTS" != "yes" ]; then
    warn "$secret_path not found in Vault — running vault-secrets.sh..."
    bash scripts/vault-secrets.sh
    break
  else
    log "$secret_path exists in Vault ✓"
  fi
done

get_vault_auth_sa_jwt() {
  local jwt
  jwt=$(kubectl get secret vault-auth-sa-token -n "$NAMESPACE" \
    -o jsonpath='{.data.token}' 2>/dev/null \
    | python3 -c "import sys,base64; raw=sys.stdin.read().strip(); print(base64.b64decode(raw).decode() if raw else '')" \
    2>/dev/null || true)
  if [ -z "$jwt" ]; then
    jwt=$(kubectl create token vault-auth-sa -n "$NAMESPACE" --duration=10m 2>/dev/null || true)
  fi
  printf '%s' "$jwt"
}

TEST_JWT=$(get_vault_auth_sa_jwt)
LOGIN_ERR_FILE=$(mktemp)
if [ -z "$TEST_JWT" ] || ! vault write -format=json auth/kubernetes/login \
  role=app-role jwt="$TEST_JWT" >/dev/null 2>"$LOGIN_ERR_FILE"; then
  warn "Vault Kubernetes login test failed — refreshing auth config and roles..."
  [ -s "$LOGIN_ERR_FILE" ] && warn "Initial login error: $(tr '\n' ' ' < "$LOGIN_ERR_FILE")"
  bash scripts/vault-secrets.sh
  TEST_JWT=$(get_vault_auth_sa_jwt)
  : > "$LOGIN_ERR_FILE"
  if [ -z "$TEST_JWT" ] || ! vault write -format=json auth/kubernetes/login \
    role=app-role jwt="$TEST_JWT" >/dev/null 2>"$LOGIN_ERR_FILE"; then
    [ -s "$LOGIN_ERR_FILE" ] && warn "Final login error: $(tr '\n' ' ' < "$LOGIN_ERR_FILE")"
    fail "Vault Kubernetes login still fails for vault-auth-sa/app-role."
  fi
fi
rm -f "$LOGIN_ERR_FILE"
log "Vault Kubernetes auth login works for vault-auth-sa/app-role ✓"

# ── FIX D: Vault injection label ──────────────────────────────────────────────
title "Step 0e — Checking Vault Injector Label"

INJ_LABEL=$(kubectl get namespace "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.vault-injection}' 2>/dev/null || true)
if [ "$INJ_LABEL" != "enabled" ]; then
  warn "Adding vault-injection=enabled to namespace '$NAMESPACE'..."
  kubectl label namespace "$NAMESPACE" vault-injection=enabled --overwrite
fi
log "Namespace '$NAMESPACE' vault-injection=enabled ✓"

# ── Ingress Controller ────────────────────────────────────────────────────────
title "Step 1 — NGINX Ingress Controller Check"

INGRESS_READY=false
if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
  log "ingress-nginx namespace exists"
  if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
    warn "ingress-nginx namespace exists but controller deployment is missing — applying manifest..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml
  fi
else
  warn "Installing NGINX Ingress Controller..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml
fi

if wait_deployment_or_debug ingress-nginx ingress-nginx-controller 300s; then
  INGRESS_READY=true
  log "NGINX Ingress Controller is ready ✓"
else
  warn "NGINX Ingress Controller is not ready yet. The app will deploy, but Ingress/DNS may need another run."
fi

# ── cert-manager ───────────────────────────────────────────────────────────────
title "Step 2 — cert-manager Check"

CERT_MANAGER_READY=false
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  log "cert-manager namespace exists"
  if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1 || \
     ! kubectl get deployment cert-manager-cainjector -n cert-manager >/dev/null 2>&1 || \
     ! kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
    warn "cert-manager namespace exists but one or more deployments are missing — applying manifest..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
  fi
else
  warn "Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
fi

CM_OK=true
for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
  wait_deployment_or_debug cert-manager "$deployment" 300s || CM_OK=false
done

if $CM_OK; then
  CERT_MANAGER_READY=true
  log "cert-manager installed and ready ✓"
else
  warn "cert-manager is still starting or blocked. Continuing app deploy and skipping TLS issuer for now."
  warn "Run this script again after fixing the cert-manager pod events shown above."
fi

# ── Apply namespace and ConfigMaps ─────────────────────────────────────────────
title "Step 3 — Namespace & ConfigMaps"

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml       -n "$NAMESPACE"
kubectl apply -f k8s/nginx-configmap.yaml -n "$NAMESPACE"
kubectl apply -f vault/vault-auth.yaml    -n "$NAMESPACE"
log "Namespace, ConfigMaps, and Vault auth applied"

# ── Pre-flight image check ─────────────────────────────────────────────────────
title "Step 4 — Pre-Flight Image Check"

for svc in frontend backend; do
  image="${REGISTRY}/${svc}:${VERSION}"
  if gcloud artifacts docker images describe "$image" --quiet &>/dev/null; then
    log "Image verified: $image ✓"
  else
    err "Image not found in GAR: $image"
    err "Rebuild and push: bash scripts/build-images.sh && bash scripts/push-images.sh"
    exit 1
  fi
done

# ── Apply ClusterIssuer before Ingress ────────────────────────────────────────
title "Step 5 — cert-manager ClusterIssuer"

if ! $CERT_MANAGER_READY; then
  warn "Skipping ClusterIssuer because cert-manager is not Ready."
elif [ -f cert-manager/cluster-issuer.yaml ]; then
  kubectl apply -f cert-manager/cluster-issuer.yaml

  ISSUER_WAIT=0
  while [ "$ISSUER_WAIT" -lt 60 ]; do
    ISSUER_READY=$(kubectl get clusterissuer letsencrypt-prod \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$ISSUER_READY" = "True" ] && { log "ClusterIssuer Ready ✓"; break; }
    sleep 5; ISSUER_WAIT=$((ISSUER_WAIT + 5))
  done
  [ "${ISSUER_READY:-}" = "True" ] || warn "ClusterIssuer not yet Ready — proceeding"
else
  warn "cert-manager/cluster-issuer.yaml not found — TLS cert will not be issued"
fi

# ── Deploy frontend and backend ────────────────────────────────────────────────
title "Step 6 — Deploying Frontend & Backend"

log "Applying frontend resources..."
kubectl apply -f k8s/frontend-deployment.yaml -n "$NAMESPACE"
kubectl apply -f k8s/frontend-service.yaml    -n "$NAMESPACE"

log "Applying backend resources..."
kubectl apply -f k8s/backend-deployment.yaml  -n "$NAMESPACE"
kubectl apply -f k8s/backend-service.yaml     -n "$NAMESPACE"

if $INGRESS_READY; then
  log "Applying Ingress..."
  kubectl apply -f k8s/ingress.yaml -n "$NAMESPACE"
else
  warn "Skipping Ingress because ingress-nginx is not Ready."
fi

log "Applying HPA..."
kubectl apply -f k8s/hpa.yaml -n "$NAMESPACE"

# ── Update image versions ──────────────────────────────────────────────────────
title "Step 7 — Patching Image Versions to $VERSION"

kubectl set image deployment/frontend \
  nginx="${REGISTRY}/frontend:${VERSION}" -n "$NAMESPACE"

kubectl set image deployment/backend \
  backend="${REGISTRY}/backend:${VERSION}" -n "$NAMESPACE"

# ── Wait for rollouts ──────────────────────────────────────────────────────────
title "Step 8 — Waiting for Rollouts"

log "Waiting for frontend rollout..."
log "(Vault Agent init container will authenticate and populate /vault/secrets/)"
rollout_or_debug frontend 240s

log "Waiting for backend rollout..."
log "(Backend sources /vault/secrets/app-creds before starting Node.js)"
rollout_or_debug backend 240s

log "All rollouts complete ✓"

# ── Get Load Balancer IP and print DNS instruction ─────────────────────────────
title "Step 9 — DNS Configuration"

LB_IP=""
LB_WAIT=0
while [ -z "$LB_IP" ] && [ "$LB_WAIT" -lt 120 ]; do
  if $INGRESS_READY; then
    LB_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  if [ -z "$LB_IP" ]; then
    LB_IP=$(kubectl get svc frontend-service -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  [ -z "$LB_IP" ] && { sleep 10; LB_WAIT=$((LB_WAIT + 10)); }
done

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Add this DNS A Record in your registrar for gt.tc:${NC}"
echo ""
if [ -n "$LB_IP" ]; then
  printf "  ${GREEN}%-8s  %-20s  %-16s  %-6s${NC}\n" "Type" "Name" "Value" "TTL"
  printf "  ${GREEN}%-8s  %-20s  %-16s  %-6s${NC}\n" "A" "enterprise-app" "$LB_IP" "300"
  echo ""
  echo -e "  Then run:  ${CYAN}bash scripts/dns-setup.sh${NC}"
else
  warn "  Load Balancer IP not yet assigned."
  warn "  Check: kubectl get svc ingress-nginx-controller -n ingress-nginx"
  warn "  Or fallback: kubectl get svc frontend-service -n $NAMESPACE"
fi
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
title "Deployment Summary"

log "Version:      $VERSION"
log "Namespace:    $NAMESPACE"
log "Registry:     $REGISTRY"
log "Domain:       https://$DOMAIN  (active after DNS setup)"
log "Vault:        $VAULT_ADDR (unsealed ✓, secrets injected ✓)"
echo ""
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
log "✅ deploy-k8s.sh complete!"
log "Next steps:"
info "  1. Add DNS A Record (see box above)"
info "  2. bash scripts/dns-setup.sh        — guided DNS + TLS cert setup"
info "  3. bash scripts/verify-deployment.sh — full stack verification"
