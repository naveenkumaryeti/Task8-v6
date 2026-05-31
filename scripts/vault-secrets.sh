#!/usr/bin/env bash
# ============================================================
# scripts/vault-secrets.sh  —  FULLY AUTOMATED
# ============================================================

set -euo pipefail
IFS=$'\n\t'

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
APP_NAMESPACE="${APP_NAMESPACE:-production}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-8200}"
INIT_KEYS_FILE="${VAULT_INIT_KEYS_FILE:-vault-init-keys.json}"
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_LOCAL_PORT}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}${BOLD}━━━━ $* ━━━━${NC}"; }

OWN_PF_PID=""
CA_CERT_FILE=""
cleanup() {
  [ -n "$CA_CERT_FILE" ] && rm -f "$CA_CERT_FILE" 2>/dev/null || true
  if [ -n "$OWN_PF_PID" ] && kill -0 "$OWN_PF_PID" 2>/dev/null; then
    warn "Stopping port-forward (PID $OWN_PF_PID)..."
    kill "$OWN_PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$VAULT_LOCAL_PORT" 2>/dev/null; return $?
  fi
  (echo >/dev/tcp/127.0.0.1/"$VAULT_LOCAL_PORT") 2>/dev/null; return $?
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Gather everything from kubectl BEFORE starting port-forward
#
# ROOT CAUSE OF PORT-FORWARD DEATH:
#   kubectl port-forward runs as a background process (&). Any subsequent
#   bash subshell $(...) that calls kubectl — even `kubectl config view` —
#   forks a child that inherits the parent's file descriptors. On Linux,
#   that child inherits the write-end of the pipe that port-forward uses
#   for its stdin/stdout. When the child exits it closes that FD, which
#   signals EOF to port-forward, killing the tunnel.
#
# FIX: Run ALL kubectl calls in Phase 1, before port-forward starts.
#   Store results in plain files on disk. Phase 2 (Vault config) reads
#   only from those files and from vault CLI — zero kubectl calls.
# ══════════════════════════════════════════════════════════════════════════════

title "Phase 1 — Pre-flight: Gathering Kubernetes data (before port-forward)"

# ── Prerequisites ──────────────────────────────────────────────────────────────
command -v vault   >/dev/null 2>&1 || fail "vault CLI not found."
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found."
command -v openssl >/dev/null 2>&1 || fail "openssl not found."
command -v python3 >/dev/null 2>&1 || fail "python3 not found."
log "Prerequisites satisfied"

# Ensure the ServiceAccount, stable reviewer-token Secret, and TokenReview RBAC
# exist before we configure Vault's Kubernetes auth method.
log "Applying namespace and Vault auth resources..."
kubectl apply -f k8s/namespace.yaml >/dev/null
kubectl apply -f vault/vault-auth.yaml -n "$APP_NAMESPACE" >/dev/null
log "Vault auth Kubernetes resources are applied"

# ── Auto-load VAULT_TOKEN ──────────────────────────────────────────────────────
if [ -z "${VAULT_TOKEN:-}" ]; then
  warn "VAULT_TOKEN not set — attempting auto-load..."
  if [ -f /tmp/.vault-env ]; then
    # shellcheck disable=SC1091
    source /tmp/.vault-env
    log "Loaded from /tmp/.vault-env"
  elif [ -f "$INIT_KEYS_FILE" ]; then
    VAULT_TOKEN=$(python3 -c "
import json
with open('$INIT_KEYS_FILE') as f:
    d = json.load(f)
print(d.get('root_token', ''))
" 2>/dev/null || true)
    [ -n "$VAULT_TOKEN" ] || fail "root_token not found in $INIT_KEYS_FILE"
    log "Loaded from $INIT_KEYS_FILE"
  elif command -v gcloud >/dev/null 2>&1; then
    gcloud secrets versions access latest \
      --secret=vault-init-keys --project="$PROJECT_ID" \
      > "$INIT_KEYS_FILE" 2>/dev/null || \
      fail "VAULT_TOKEN not found anywhere. Run: export VAULT_TOKEN=<root_token>"
    VAULT_TOKEN=$(python3 -c "
import json
with open('$INIT_KEYS_FILE') as f:
    d = json.load(f)
print(d.get('root_token', ''))
" 2>/dev/null || true)
    [ -n "$VAULT_TOKEN" ] || fail "Could not extract root_token from Secret Manager"
    log "Loaded from GCP Secret Manager"
  else
    fail "VAULT_TOKEN not set. Run: export VAULT_TOKEN=<root_token>"
  fi
fi
export VAULT_ADDR VAULT_TOKEN
log "VAULT_TOKEN loaded (${VAULT_TOKEN:0:10}...)"

# ── Collect: Kubernetes API server URL ────────────────────────────────────────
#
# Vault itself runs inside Kubernetes, so this must be an address reachable from
# the Vault pod, not the external kubeconfig endpoint used by your laptop.
KUBE_HOST="${KUBE_HOST:-https://kubernetes.default.svc:443}"
log "Kubernetes API server for Vault: $KUBE_HOST"

# ── Collect: CA cert → write to temp file ─────────────────────────────────────
#
# We try three strategies and write the PEM to a temp file immediately.
# After this block CA_CERT_FILE contains a valid path to a PEM file, or we fail.
# Python here only does base64 decode + file write — no subprocess calls.

log "Extracting Kubernetes CA cert..."

# Strategy 0: kube-root-ca.crt ConfigMap. This is the CA that in-cluster pods
# use for https://kubernetes.default.svc:443.
CA_PEM=$(kubectl get configmap kube-root-ca.crt -n "$APP_NAMESPACE" \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null || \
kubectl get configmap kube-root-ca.crt -n kube-public \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)

if [ -n "$CA_PEM" ]; then
  log "CA source: kube-root-ca.crt ConfigMap"
  CA_CERT_FILE=$(printf '%s\n' "$CA_PEM" | python3 -c "
import sys, tempfile
pem = sys.stdin.read()
tf  = tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False, newline='\n')
tf.write(pem if pem.endswith('\n') else pem + '\n')
tf.close()
print(tf.name)
" 2>/dev/null || true)
fi

# Strategy 1: certificate-authority-data (base64 inline) — standard GKE
if [ -z "${CA_CERT_FILE:-}" ]; then
  CA_B64=$(kubectl config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)
else
  CA_B64=""
fi

if [ -n "$CA_B64" ]; then
  log "CA source: kubeconfig inline base64"
  CA_CERT_FILE=$(printf '%s' "$CA_B64" | python3 -c "
import sys, base64, tempfile
raw = sys.stdin.read().strip()
pem = base64.b64decode(raw).decode('utf-8')
tf  = tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False, newline='\n')
tf.write(pem)
tf.close()
print(tf.name)
" 2>/dev/null || true)
fi

# Strategy 2: certificate-authority file path
if [ -z "${CA_CERT_FILE:-}" ]; then
  CA_FILE_PATH=$(kubectl config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)
  if [ -n "$CA_FILE_PATH" ] && [ -f "$CA_FILE_PATH" ]; then
    log "CA source: kubeconfig file path ($CA_FILE_PATH)"
    CA_CERT_FILE=$(python3 -c "
import tempfile, sys
with open(sys.argv[1]) as f:
    pem = f.read()
tf = tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False, newline='\n')
tf.write(pem)
tf.close()
print(tf.name)
" "$CA_FILE_PATH" 2>/dev/null || true)
  fi
fi

# Strategy 3: kube-root-ca.crt ConfigMap (always present on Kubernetes >= 1.20)
if [ -z "${CA_CERT_FILE:-}" ]; then
  warn "Kubeconfig CA not found — trying kube-root-ca.crt ConfigMap..."
  CA_PEM=$(kubectl get configmap kube-root-ca.crt -n kube-public \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || \
  kubectl get configmap kube-root-ca.crt -n "$APP_NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
  if [ -n "$CA_PEM" ]; then
    log "CA source: kube-root-ca.crt ConfigMap"
    CA_CERT_FILE=$(printf '%s\n' "$CA_PEM" | python3 -c "
import sys, tempfile
pem = sys.stdin.read()
tf  = tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False, newline='\n')
tf.write(pem if pem.endswith('\n') else pem + '\n')
tf.close()
print(tf.name)
" 2>/dev/null || true)
  fi
fi

[ -z "${CA_CERT_FILE:-}" ] || [ ! -f "${CA_CERT_FILE:-/nonexistent}" ] && \
  fail "Could not obtain Kubernetes CA cert via any strategy."
log "CA cert written to $CA_CERT_FILE"

# ── Collect: stable ServiceAccount reviewer token ─────────────────────────────
log "Obtaining stable vault-auth-sa reviewer token..."
TOKEN_REVIEWER_JWT=""
for i in $(seq 1 20); do
  TOKEN_REVIEWER_JWT=$(kubectl get secret vault-auth-sa-token -n "$APP_NAMESPACE" \
    -o jsonpath='{.data.token}' 2>/dev/null \
    | python3 -c "import sys,base64; raw=sys.stdin.read().strip(); print(base64.b64decode(raw).decode() if raw else '')" \
    2>/dev/null || true)
  [ -n "$TOKEN_REVIEWER_JWT" ] && break
  warn "Waiting for vault-auth-sa-token to be populated ($i/20)..."
  sleep 2
done

if [ -z "$TOKEN_REVIEWER_JWT" ]; then
  warn "Stable token Secret not ready — falling back to kubectl create token."
  warn "This fallback token can expire; rerun this script after vault-auth.yaml is applied."
  TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth-sa \
    -n "$APP_NAMESPACE" --duration=24h 2>/dev/null || true)
fi
[ -z "$TOKEN_REVIEWER_JWT" ] && \
  fail "Cannot obtain ServiceAccount token for vault-auth-sa in $APP_NAMESPACE"
log "ServiceAccount token obtained (${TOKEN_REVIEWER_JWT:0:20}...)"

# ── Write token to temp file (avoids shell variable passing to vault write) ───
TOKEN_FILE=$(mktemp)
printf '%s' "$TOKEN_REVIEWER_JWT" > "$TOKEN_FILE"
log "All Kubernetes data collected ✓"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Start port-forward, then run all Vault CLI commands
#
# Zero kubectl calls from this point forward.
# All Vault CLI commands use only: VAULT_ADDR, VAULT_TOKEN, CA_CERT_FILE,
# TOKEN_FILE, KUBE_HOST — all set above before port-forward started.
# ══════════════════════════════════════════════════════════════════════════════

title "Phase 2 — Vault Configuration (port-forward active)"

# ── Start port-forward if needed ──────────────────────────────────────────────
if port_open; then
  log "Vault already reachable at $VAULT_ADDR ✓"
else
  warn "Starting port-forward on 127.0.0.1:${VAULT_LOCAL_PORT}..."

  OLD_PF=$(lsof -ti tcp:"$VAULT_LOCAL_PORT" 2>/dev/null || true)
  [ -n "$OLD_PF" ] && { kill "$OLD_PF" 2>/dev/null || true; sleep 1; }

  # Get pod name — last kubectl call before port-forward
  VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -z "$VAULT_POD" ] && VAULT_POD="${VAULT_NAMESPACE%-*}-0"
  [ -z "$VAULT_POD" ] && fail "No running Vault pod found. Run deploy-vault.sh first."

  # Start port-forward with stdin redirected from /dev/null so it holds no
  # FDs connected to this script's stdin/stdout pipe chain.
  kubectl port-forward --address 127.0.0.1 \
    "pod/$VAULT_POD" -n "$VAULT_NAMESPACE" \
    "${VAULT_LOCAL_PORT}:8200" \
    </dev/null >/tmp/vault-portforward-secrets.log 2>&1 &
  OWN_PF_PID=$!

  READY=false
  for i in $(seq 1 20); do
    sleep 2
    if port_open; then READY=true; log "Port-forward ready (PID $OWN_PF_PID) ✓"; break; fi
    kill -0 "$OWN_PF_PID" 2>/dev/null || \
      fail "Port-forward died: $(cat /tmp/vault-portforward-secrets.log)"
    warn "Attempt $i/20 — waiting for tunnel..."
  done
  $READY || fail "Port-forward did not open in 40s"
  VAULT_ADDR="http://127.0.0.1:${VAULT_LOCAL_PORT}"
  export VAULT_ADDR
fi

# ── Verify unsealed ────────────────────────────────────────────────────────────
log "Checking Vault seal status..."
SEALED=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null \
  || echo "True")
[ "$SEALED" = "True" ] && fail "Vault is sealed. Run deploy-vault.sh first."
log "Vault is unsealed ✓"
vault status | grep -E "Sealed|Version" | while read -r l; do log "  $l"; done

# ── KV v2 ─────────────────────────────────────────────────────────────────────
title "Enabling KV v2 Secrets Engine"
vault secrets enable -path=secret kv-v2 2>/dev/null || \
  warn "KV v2 already enabled — continuing"
log "KV v2 at path 'secret/' is ready"

generate_password() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-32; }
generate_key()      { openssl rand -hex 64; }

# ── MySQL Secrets ─────────────────────────────────────────────────────────────
title "Writing MySQL Secrets → secret/mysql"
MYSQL_ROOT_PASSWORD=$(generate_password)
MYSQL_APP_PASSWORD=$(generate_password)
vault kv put secret/mysql \
  root_password="$MYSQL_ROOT_PASSWORD" \
  app_password="$MYSQL_APP_PASSWORD"   \
  app_user="appuser"                   \
  host="mysql-service"                 \
  port="3306"                          \
  database="appdb"
log "MySQL secrets written"
unset MYSQL_ROOT_PASSWORD MYSQL_APP_PASSWORD

# ── Application Secrets ───────────────────────────────────────────────────────
title "Writing Application Secrets → secret/app"
JWT_SECRET=$(generate_key)
SESSION_SECRET=$(generate_key)
API_KEY=$(generate_password)
vault kv put secret/app \
  jwt_secret="$JWT_SECRET"         \
  session_secret="$SESSION_SECRET" \
  api_key="$API_KEY"
log "App secrets written"
unset JWT_SECRET SESSION_SECRET API_KEY

# ── Kubernetes Auth ────────────────────────────────────────────────────────────
title "Configuring Vault Kubernetes Auth"
set +e; vault auth enable kubernetes 2>/dev/null; AUTH_RC=$?; set -e
[ "$AUTH_RC" -eq 0 ] && log "Kubernetes auth enabled" || warn "Kubernetes auth already enabled — reconfiguring..."

# Write auth config using files collected in Phase 1.
# token_reviewer_jwt read from file via @TOKEN_FILE — no shell variable passed.
vault write auth/kubernetes/config \
  token_reviewer_jwt=@"$TOKEN_FILE" \
  kubernetes_host="$KUBE_HOST"      \
  kubernetes_ca_cert=@"$CA_CERT_FILE" \
  disable_iss_validation=true         \
  disable_local_ca_jwt=false

rm -f "$TOKEN_FILE" "$CA_CERT_FILE"
CA_CERT_FILE=""
log "Kubernetes auth configured (host: $KUBE_HOST)"

# ── Vault Policies ────────────────────────────────────────────────────────────
title "Writing Vault Policies"

vault policy write app-backend-policy - <<'HCL'
path "secret/data/app"       { capabilities = ["read"] }
path "secret/data/mysql"     { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "secret/metadata/*"     { capabilities = ["list"] }
HCL
log "Policy 'app-backend-policy' written"

vault policy write mysql-policy - <<'HCL'
path "secret/data/mysql"     { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
HCL
log "Policy 'mysql-policy' written"

# ── Kubernetes Auth Roles ─────────────────────────────────────────────────────
title "Creating Kubernetes Auth Roles"
vault write auth/kubernetes/role/app-role \
  bound_service_account_names="vault-auth-sa"      \
  bound_service_account_namespaces="$APP_NAMESPACE" \
  policies="app-backend-policy"                     \
  ttl="1h"                                          \
  max_ttl="24h"
log "Role 'app-role' created"

vault write auth/kubernetes/role/mysql-role \
  bound_service_account_names="vault-auth-sa"      \
  bound_service_account_namespaces="$APP_NAMESPACE" \
  policies="mysql-policy"                           \
  ttl="1h"
log "Role 'mysql-role' created"

# ── Verify ────────────────────────────────────────────────────────────────────
title "Verification"
log "Verifying secret/mysql..."
vault kv get -format=json secret/mysql | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)['data']['data']
print(f\"  app_user={d['app_user']}  host={d['host']}  database={d['database']}\")
"
log "Verifying secret/app..."
vault kv get -format=json secret/app | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)['data']['data']
print(f'  keys present: {list(d.keys())}')
"

# ── Summary ───────────────────────────────────────────────────────────────────
title "Vault Secrets Configuration Complete"
echo ""
echo -e "${BOLD}  Secret paths:${NC}"
echo -e "  ${CYAN}secret/mysql${NC}  → root_password, app_password, app_user, host, port, database"
echo -e "  ${CYAN}secret/app${NC}    → jwt_secret, session_secret, api_key"
echo ""
echo -e "${BOLD}  Kubernetes auth roles:${NC}"
echo -e "  ${CYAN}app-role${NC}    → frontend/backend pods (reads secret/app + secret/mysql)"
echo -e "  ${CYAN}mysql-role${NC}  → mysql pod (reads secret/mysql only)"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo -e "  ${CYAN}bash scripts/deploy-database.sh${NC}"
echo -e "  ${CYAN}bash scripts/deploy-k8s.sh${NC}"
echo ""
log "✅ vault-secrets.sh complete!"
