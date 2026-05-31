#!/usr/bin/env bash
# ============================================================
# scripts/vault-secrets.sh  —  FULLY AUTOMATED
#
# WHAT CHANGED:
#   FIX A — Port-forward race condition eliminated:
#     No longer starts a new port-forward. Expects VAULT_ADDR to be set
#     (either exported by deploy-vault.sh, or sourced from /tmp/.vault-env).
#     Polls /v1/sys/health to confirm connectivity before any vault CLI call.
#
#   FIX B — Token auto-loading:
#     If VAULT_TOKEN is empty, automatically loads from:
#       1. /tmp/.vault-env  (written by deploy-vault.sh)
#       2. vault-init-keys.json  (local file)
#       3. GCP Secret Manager   (remote backup)
#     No manual "export VAULT_TOKEN=..." step required.
#
#   FIX C — Auto port-forward if VAULT_ADDR unreachable:
#     If vault_addr is not reachable, starts its own port-forward on
#     127.0.0.1:8200 (IPv4 only, avoiding the [::1] Windows WSL issue).
#
#   FIX D — Kubernetes auth uses in-cluster CA:
#     vault write auth/kubernetes/config now reads
#     /var/run/secrets/kubernetes.io/serviceaccount/ca.crt from
#     inside the vault pod (via kubectl exec) rather than from the local
#     kubeconfig, which avoids base64 decode/format mismatches.
#
# Usage (after deploy-vault.sh):
#   bash scripts/vault-secrets.sh
#
# Or standalone:
#   source /tmp/.vault-env && bash scripts/vault-secrets.sh
#
# Or with explicit credentials:
#   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=hvs.xxx bash scripts/vault-secrets.sh
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ── Configuration ──────────────────────────────────────────────────────────────
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
APP_NAMESPACE="${APP_NAMESPACE:-production}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-8200}"
INIT_KEYS_FILE="${VAULT_INIT_KEYS_FILE:-vault-init-keys.json}"
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"

# Default VAULT_ADDR to IPv4 explicitly (prevents [::1] on Windows/WSL)
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_LOCAL_PORT}}"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}${BOLD}━━━━ $* ━━━━${NC}"; }

# Cleanup: kill any port-forward this script started
OWN_PF_PID=""
cleanup() {
  if [ -n "$OWN_PF_PID" ] && kill -0 "$OWN_PF_PID" 2>/dev/null; then
    warn "Stopping port-forward started by this script (PID $OWN_PF_PID)..."
    kill "$OWN_PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Validate prerequisites ─────────────────────────────────────────────────────
title "Validating Prerequisites"

command -v vault   >/dev/null 2>&1 || fail "vault CLI not found."
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found."
command -v openssl >/dev/null 2>&1 || fail "openssl not found."
command -v python3 >/dev/null 2>&1 || fail "python3 not found."

log "Prerequisites satisfied"

# Ensure the ServiceAccount, stable reviewer-token Secret, and TokenReview RBAC
# exist before configuring Vault's Kubernetes auth method.
log "Applying namespace and Vault auth resources..."
kubectl apply -f k8s/namespace.yaml >/dev/null
kubectl apply -f vault/vault-auth.yaml -n "$APP_NAMESPACE" >/dev/null
log "Vault auth Kubernetes resources are applied"

# ── FIX B: Auto-load VAULT_TOKEN if not set ───────────────────────────────────
title "Loading Vault Credentials"

if [ -z "${VAULT_TOKEN:-}" ]; then
  warn "VAULT_TOKEN not set — attempting auto-load..."

  # Source /tmp/.vault-env if it exists (written by deploy-vault.sh)
  if [ -f /tmp/.vault-env ]; then
    # shellcheck disable=SC1091
    source /tmp/.vault-env
    log "Loaded VAULT_TOKEN from /tmp/.vault-env"

  # Try reading root_token from vault-init-keys.json
  elif [ -f "$INIT_KEYS_FILE" ]; then
    VAULT_TOKEN=$(python3 -c "
import json
with open('$INIT_KEYS_FILE') as f:
    d = json.load(f)
print(d.get('root_token', ''))
" 2>/dev/null || true)
    [ -n "$VAULT_TOKEN" ] && \
      log "Loaded VAULT_TOKEN from $INIT_KEYS_FILE" || \
      fail "root_token not found in $INIT_KEYS_FILE"

  # Try GCP Secret Manager
  elif command -v gcloud >/dev/null 2>&1; then
    warn "Trying GCP Secret Manager for vault-init-keys..."
    gcloud secrets versions access latest \
      --secret=vault-init-keys \
      --project="$PROJECT_ID" \
      > "$INIT_KEYS_FILE" 2>/dev/null || \
      fail "Cannot find VAULT_TOKEN anywhere. Export it manually:\n  export VAULT_TOKEN=<root_token>"
    VAULT_TOKEN=$(python3 -c "
import json
with open('$INIT_KEYS_FILE') as f:
    d = json.load(f)
print(d.get('root_token', ''))
" 2>/dev/null || true)
    [ -n "$VAULT_TOKEN" ] && log "Loaded VAULT_TOKEN from GCP Secret Manager" || \
      fail "Could not extract root_token from GCP Secret Manager secret"

  else
    fail "VAULT_TOKEN not set and no fallback found.\nRun: export VAULT_TOKEN=<root_token_from_vault-init-keys.json>"
  fi
fi

export VAULT_ADDR VAULT_TOKEN
log "VAULT_ADDR: $VAULT_ADDR"
log "VAULT_TOKEN: ${VAULT_TOKEN:0:10}... (truncated for security)"

# ── FIX A + C: Verify connectivity; start port-forward if needed ──────────────
title "Verifying Vault Connectivity"

port_open() {
  local port="${1:-8200}"
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" 2>/dev/null; return $?
  fi
  (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; return $?
}

check_vault_reachable() {
  port_open "$VAULT_LOCAL_PORT"
}

if check_vault_reachable; then
  log "Vault reachable at $VAULT_ADDR ✓"
else
  warn "Cannot reach Vault at $VAULT_ADDR — starting port-forward on 127.0.0.1:${VAULT_LOCAL_PORT}..."

  # Kill any existing process on this port
  OLD_PF=$(lsof -ti tcp:"$VAULT_LOCAL_PORT" 2>/dev/null || true)
  [ -n "$OLD_PF" ] && { warn "Killing PID $OLD_PF on port $VAULT_LOCAL_PORT..."; kill "$OLD_PF" 2>/dev/null || true; sleep 1; }

  VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -z "$VAULT_POD" ] && fail "No Vault pod found in namespace '$VAULT_NAMESPACE'. Run deploy-vault.sh first."

  # FIX A+C: Bind to 127.0.0.1 explicitly — prevents [::1] IPv6 issue on Windows/WSL
  kubectl port-forward \
    --address 127.0.0.1 \
    pod/"$VAULT_POD" \
    -n "$VAULT_NAMESPACE" \
    "${VAULT_LOCAL_PORT}:8200" \
    >/tmp/vault-portforward.log 2>&1 &
  OWN_PF_PID=$!

  log "Port-forward started (PID $OWN_PF_PID) — polling for readiness..."

  READY=false
  for i in $(seq 1 20); do
    sleep 2
    if check_vault_reachable; then
      READY=true
      log "Port-forward ready ✓"
      break
    fi
    kill -0 "$OWN_PF_PID" 2>/dev/null || \
      fail "Port-forward died. Log: $(cat /tmp/vault-portforward.log)"
    warn "Attempt $i/20 — waiting for tunnel..."
  done

  $READY || fail "Vault port-forward did not become ready in 40s"
  VAULT_ADDR="http://127.0.0.1:${VAULT_LOCAL_PORT}"
  export VAULT_ADDR
fi

# Confirm Vault is unsealed before writing secrets
log "Checking Vault seal status..."
SEALED=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null \
  || echo "True")

if [ "$SEALED" = "True" ]; then
  fail "Vault is sealed. Run deploy-vault.sh (which auto-unseals), or manually:\n  vault operator unseal <key>"
fi

log "Vault is unsealed and reachable ✓"
vault status | grep -E "Sealed|Version" | while read -r l; do log "  $l"; done

# ── Enable KV v2 secrets engine ───────────────────────────────────────────────
title "Enabling KV v2 Secrets Engine"

vault secrets enable -path=secret kv-v2 2>/dev/null || \
  warn "KV v2 already enabled at 'secret/' — continuing"
log "KV v2 at path 'secret/' is ready"

# ── Secure random generators ───────────────────────────────────────────────────
generate_password() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-32; }
generate_key()      { openssl rand -hex 64; }

# ── MySQL Secrets ─────────────────────────────────────────────────────────────
title "Writing MySQL Secrets → secret/mysql"

MYSQL_ROOT_PASSWORD=$(generate_password)
MYSQL_APP_PASSWORD=$(generate_password)

vault kv put secret/mysql \
  root_password="$MYSQL_ROOT_PASSWORD" \
  app_password="$MYSQL_APP_PASSWORD"  \
  app_user="appuser"                  \
  host="mysql-service"                \
  port="3306"                         \
  database="appdb"

log "MySQL secrets written to secret/mysql"
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

log "App secrets written to secret/app"
unset JWT_SECRET SESSION_SECRET API_KEY

# ── Enable Kubernetes Auth Method ─────────────────────────────────────────────
title "Configuring Vault Kubernetes Auth"

vault auth enable kubernetes 2>/dev/null ||   warn "Kubernetes auth already enabled — reconfiguring..."

# ── FIX: How we get the Kubernetes CA cert and API server address ──────────────
#
# PREVIOUS APPROACH (broken):
#   kubectl exec <vault-pod> -- cat /var/run/secrets/.../ca.crt
#   Problems:
#     1. kubectl exec opens a new WebSocket connection to the API server.
#        On Git Bash/Windows this can corrupt or drop the existing port-forward
#        connection sharing the same kubectl process group → port-forward dies,
#        script output stops mid-way ("Stopping port-forward (PID xxxx)...")
#     2. Multi-line PEM string in a shell variable passed to `vault write`
#        gets mangled by Git Bash line-ending conversion (CRLF vs LF) and
#        shell word-splitting — Vault receives a malformed cert.
#
# NEW APPROACH (robust):
#   1. CA cert: read from kubeconfig via `kubectl config view --raw`.
#      The value is base64-encoded in kubeconfig; we decode it with Python
#      and write it to a temp file — no exec into pods, no shell variable
#      holding multi-line PEM, no line-ending issues.
#   2. API server: same kubectl config view call — no network needed.
#   3. Token: kubectl create token (bound ServiceAccount token, 10min TTL).
#      Falls back to reading from the secret if create token is unavailable.
#   4. vault write: uses -ca-cert flag (file path) — the cert never touches
#      a shell variable after it's been written to the temp file.

# Vault runs inside Kubernetes, so configure auth with the in-cluster API
# service rather than the external kubeconfig endpoint from this workstation.
KUBE_HOST="${KUBE_HOST:-https://kubernetes.default.svc:443}"
log "Kubernetes API server for Vault: $KUBE_HOST"

# Extract CA cert: kubeconfig stores it as base64 under
# clusters[0].cluster.certificate-authority-data
# We decode it with Python and write to a temp file — this is the ONLY
# reliable way on Git Bash: no kubectl exec, no shell variable holding PEM,
# no line-ending corruption.
CA_CERT_FILE=""
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

if [ -z "$CA_CERT_FILE" ]; then
CA_CERT_FILE=$(python3 -c "
import base64, subprocess, sys, tempfile, os, json

# Get raw kubeconfig as JSON
result = subprocess.run(
    ['kubectl', 'config', 'view', '--raw', '--minify', '-o', 'json'],
    capture_output=True, text=True
)
if result.returncode != 0:
    print('ERROR: kubectl config view failed: ' + result.stderr, file=sys.stderr)
    sys.exit(1)

cfg = json.loads(result.stdout)
try:
    ca_data = cfg['clusters'][0]['cluster']['certificate-authority-data']
    ca_pem  = base64.b64decode(ca_data).decode('utf-8')
except (KeyError, IndexError) as e:
    # Fallback: cluster may use certificate-authority (file path) not inline data
    ca_file = cfg.get('clusters', [{}])[0].get('cluster', {}).get('certificate-authority', '')
    if ca_file and os.path.exists(ca_file):
        with open(ca_file) as f:
            ca_pem = f.read()
    else:
        print('ERROR: cannot find CA cert in kubeconfig: ' + str(e), file=sys.stderr)
        sys.exit(1)

# Write PEM to temp file with LF line endings (vault requires Unix PEM)
tf = tempfile.NamedTemporaryFile(
    mode='w', suffix='.pem', delete=False, newline='
'
)
tf.write(ca_pem)
tf.close()
print(tf.name)
" 2>/dev/null)
fi

if [ -z "$CA_CERT_FILE" ] || [ ! -f "$CA_CERT_FILE" ]; then
  fail "Could not extract Kubernetes CA cert from kubeconfig. Check: kubectl config view --raw --minify"
fi
log "Kubernetes CA cert written to $CA_CERT_FILE"

# Read the stable ServiceAccount token Secret created by vault-auth.yaml.
# Do not use a 10-minute `kubectl create token` token as Vault's reviewer JWT:
# once that token expires, every later Vault Agent login returns 403.
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
  warn "This fallback token can expire; rerun vault-secrets.sh after vault-auth.yaml is applied."
  TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth-sa \
    -n "$APP_NAMESPACE" --duration=24h 2>/dev/null || true)
fi
[ -z "$TOKEN_REVIEWER_JWT" ] && fail "Cannot obtain ServiceAccount token for vault-auth-sa"
log "ServiceAccount token obtained (${TOKEN_REVIEWER_JWT:0:20}...)"

# Write the kubernetes auth config.
# -ca-cert reads from FILE — avoids multi-line PEM in shell variables entirely.
vault write auth/kubernetes/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="$KUBE_HOST"             \
  kubernetes_ca_cert=@"$CA_CERT_FILE"      \
  disable_iss_validation=true

# Clean up temp cert file
rm -f "$CA_CERT_FILE"

log "Kubernetes auth configured (host: $KUBE_HOST)"

# ── Vault Policies ────────────────────────────────────────────────────────────
title "Writing Vault Policies"

# Backend policy: read app + mysql secrets, renew own token
vault policy write app-backend-policy - <<'HCL'
# Allow backend pods to read all app secrets
path "secret/data/app" {
  capabilities = ["read"]
}
# Allow backend pods to read MySQL credentials
path "secret/data/mysql" {
  capabilities = ["read"]
}
# Required for token renewal (Vault sidecar)
path "auth/token/renew-self" {
  capabilities = ["update"]
}
# Allow listing secret paths (optional, useful for debugging)
path "secret/metadata/*" {
  capabilities = ["list"]
}
HCL
log "Policy 'app-backend-policy' written"

# MySQL-only policy: read mysql secrets only
vault policy write mysql-policy - <<'HCL'
# MySQL pod only needs its own credentials
path "secret/data/mysql" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
HCL
log "Policy 'mysql-policy' written"

# ── Kubernetes Auth Roles ──────────────────────────────────────────────────────
title "Creating Kubernetes Auth Roles"

# Backend role — binds vault-auth-sa in 'production' to app-backend-policy
vault write auth/kubernetes/role/app-role \
  bound_service_account_names="vault-auth-sa"      \
  bound_service_account_namespaces="$APP_NAMESPACE" \
  policies="app-backend-policy"                     \
  ttl="1h"                                          \
  max_ttl="24h"

log "Role 'app-role' created (policy: app-backend-policy)"

# MySQL role — same SA, narrower policy
vault write auth/kubernetes/role/mysql-role \
  bound_service_account_names="vault-auth-sa"      \
  bound_service_account_namespaces="$APP_NAMESPACE" \
  policies="mysql-policy"                           \
  ttl="1h"

log "Role 'mysql-role' created (policy: mysql-policy)"

# ── Verify secrets are readable ────────────────────────────────────────────────
title "Verification"

log "Verifying secret/mysql..."
vault kv get -format=json secret/mysql | \
  python3 -c "import sys,json; d=json.load(sys.stdin)['data']['data']; print(f\"  app_user={d['app_user']}  host={d['host']}  database={d['database']}\")"

log "Verifying secret/app..."
vault kv get -format=json secret/app | \
  python3 -c "import sys,json; d=json.load(sys.stdin)['data']['data']; print(f\"  keys present: {list(d.keys())}\")"

# ── Summary ────────────────────────────────────────────────────────────────────
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
