#!/usr/bin/env bash
# ============================================================
# scripts/deploy-database.sh  —  FULLY CORRECTED
#
# ROOT CAUSE FIX — Vault Agent init container stuck in Pending:
#
#   The Vault Agent init container runs INSIDE the Kubernetes cluster.
#   It must reach Vault via the in-cluster service DNS:
#     http://vault.vault.svc.cluster.local:8200
#
#   Previously the MySQL StatefulSet annotations either lacked the
#   vault.hashicorp.com/service annotation entirely, or inherited a
#   bad default. The Vault Agent injector defaults to whatever
#   AGENT_INJECT_VAULT_ADDR was set to at injector startup — if the
#   injector started before Vault was ready, or if it defaulted to
#   http://127.0.0.1:8200, all injected agents fail to connect.
#
#   FIX: Explicitly set vault.hashicorp.com/service on every pod that
#   uses Vault Agent injection. This overrides the injector default and
#   guarantees the agent connects to the correct in-cluster address.
#
#   This script generates the MySQL manifest inline with all required
#   annotations correct, instead of relying on a static manifest file.
#
# ============================================================

set -euo pipefail
IFS=$'\n\t'

NAMESPACE="${K8S_NAMESPACE:-production}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_RELEASE="${VAULT_RELEASE:-vault}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-8200}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:${VAULT_LOCAL_PORT}}"
INIT_KEYS_FILE="${VAULT_INIT_KEYS_FILE:-vault-init-keys.json}"
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"

# In-cluster Vault service address — used by Vault Agent inside pods
# Format: http://<release>.<vault-namespace>.svc.cluster.local:8200
VAULT_K8S_ADDR="http://${VAULT_RELEASE}.${VAULT_NAMESPACE}.svc.cluster.local:8200"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}${BOLD}━━━━ $* ━━━━${NC}"; }

OWN_PF_PID=""
cleanup() {
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

# ── Step 1: Load Vault credentials ────────────────────────────────────────────
title "Step 1 — Loading Vault Credentials"

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
    [ -n "$VAULT_TOKEN" ] || fail "Cannot extract root_token from $INIT_KEYS_FILE"
    log "Loaded VAULT_TOKEN from $INIT_KEYS_FILE"
  elif command -v gcloud >/dev/null 2>&1; then
    gcloud secrets versions access latest \
      --secret=vault-init-keys --project="$PROJECT_ID" \
      > "$INIT_KEYS_FILE" 2>/dev/null || \
      fail "VAULT_TOKEN not set. Run deploy-vault.sh first."
    VAULT_TOKEN=$(python3 -c "
import json
with open('$INIT_KEYS_FILE') as f:
    d = json.load(f)
print(d.get('root_token',''))
" 2>/dev/null || true)
    [ -n "$VAULT_TOKEN" ] || fail "Could not extract root_token from GCP Secret Manager"
    log "Loaded VAULT_TOKEN from GCP Secret Manager"
  else
    fail "VAULT_TOKEN not set. Run deploy-vault.sh or: export VAULT_TOKEN=<root_token>"
  fi
fi
export VAULT_ADDR VAULT_TOKEN
log "VAULT_ADDR: $VAULT_ADDR"
log "In-cluster Vault address for agents: $VAULT_K8S_ADDR"

# ── Step 2: Verify Vault connectivity ─────────────────────────────────────────
title "Step 2 — Verifying Vault Connectivity"

if ! port_open; then
  warn "Vault not reachable at $VAULT_ADDR — starting port-forward..."

  OLD_PF=$(lsof -ti tcp:"$VAULT_LOCAL_PORT" 2>/dev/null || true)
  [ -n "$OLD_PF" ] && { kill "$OLD_PF" 2>/dev/null || true; sleep 1; }

  VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" \
    -l app.kubernetes.io/name=vault \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -z "$VAULT_POD" ] && VAULT_POD="${VAULT_RELEASE}-0"

  kubectl port-forward --address 127.0.0.1 \
    "pod/$VAULT_POD" -n "$VAULT_NAMESPACE" \
    "${VAULT_LOCAL_PORT}:8200" \
    </dev/null >/tmp/vault-pf-db.log 2>&1 &
  OWN_PF_PID=$!

  for i in $(seq 1 20); do
    sleep 2
    if port_open; then log "Port-forward ready ✓"; break; fi
    kill -0 "$OWN_PF_PID" 2>/dev/null || \
      fail "Port-forward died: $(cat /tmp/vault-pf-db.log)"
    warn "Attempt $i/20 — waiting..."
    [ "$i" -eq 20 ] && fail "Vault not reachable after 40s"
  done
  VAULT_ADDR="http://127.0.0.1:${VAULT_LOCAL_PORT}"
  export VAULT_ADDR
fi

SEALED=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null \
  || echo "True")
[ "$SEALED" = "False" ] || fail "Vault is sealed. Run deploy-vault.sh first."
log "Vault is reachable and unsealed ✓"

# ── Step 3: Apply namespace and Vault auth resources first ────────────────────
title "Step 3 — Applying Namespace and Vault Auth"
kubectl apply -f k8s/namespace.yaml
log "Namespace '$NAMESPACE' applied"
kubectl apply -f vault/vault-auth.yaml -n "$NAMESPACE"
log "vault-auth.yaml applied"

# ── Step 4: Verify Vault secrets and Kubernetes auth ──────────────────────────
title "Step 4 — Verifying Vault Secrets and Kubernetes Auth"

MYSQL_SECRET_EXISTS=$(vault kv get -format=json secret/mysql 2>/dev/null \
  | python3 -c "import sys,json; json.load(sys.stdin); print('yes')" 2>/dev/null \
  || echo "no")

if [ "$MYSQL_SECRET_EXISTS" != "yes" ]; then
  warn "secret/mysql not found — running vault-secrets.sh..."
  bash scripts/vault-secrets.sh
else
  log "secret/mysql exists in Vault ✓"
fi

# Verify the mysql-role exists in Kubernetes auth — agents use this to authenticate
MYSQL_ROLE_EXISTS=$(vault read -format=json auth/kubernetes/role/mysql-role 2>/dev/null \
  | python3 -c "import sys,json; json.load(sys.stdin); print('yes')" 2>/dev/null \
  || echo "no")
if [ "$MYSQL_ROLE_EXISTS" != "yes" ]; then
  warn "auth/kubernetes/role/mysql-role not found — running vault-secrets.sh..."
  bash scripts/vault-secrets.sh
else
  log "auth/kubernetes/role/mysql-role exists ✓"
fi

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
  role=mysql-role jwt="$TEST_JWT" >/dev/null 2>"$LOGIN_ERR_FILE"; then
  warn "Vault Kubernetes login test failed — refreshing auth config and roles..."
  [ -s "$LOGIN_ERR_FILE" ] && warn "Initial login error: $(tr '\n' ' ' < "$LOGIN_ERR_FILE")"
  bash scripts/vault-secrets.sh
  TEST_JWT=$(get_vault_auth_sa_jwt)
  : > "$LOGIN_ERR_FILE"
  if [ -z "$TEST_JWT" ] || ! vault write -format=json auth/kubernetes/login \
    role=mysql-role jwt="$TEST_JWT" >/dev/null 2>"$LOGIN_ERR_FILE"; then
    [ -s "$LOGIN_ERR_FILE" ] && warn "Final login error: $(tr '\n' ' ' < "$LOGIN_ERR_FILE")"
    fail "Vault Kubernetes login still fails for vault-auth-sa/mysql-role."
  fi
fi
rm -f "$LOGIN_ERR_FILE"
log "Vault Kubernetes auth login works for vault-auth-sa/mysql-role ✓"

# ── Step 5: Namespace label and injector webhook ──────────────────────────────
title "Step 5 — Checking Vault Injector Namespace Label"

INJECTION_LABEL=$(kubectl get namespace "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.vault-injection}' 2>/dev/null || true)
if [ "$INJECTION_LABEL" != "enabled" ]; then
  warn "Adding vault-injection=enabled label to namespace $NAMESPACE..."
  kubectl label namespace "$NAMESPACE" vault-injection=enabled --overwrite
fi
log "Namespace '$NAMESPACE' has vault-injection=enabled ✓"

WEBHOOK_ACTIVE=$(kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg \
  -o jsonpath='{.metadata.name}' 2>/dev/null || true)
[ -n "$WEBHOOK_ACTIVE" ] && log "Vault Agent Injector webhook is active ✓" || \
  warn "Vault Agent Injector webhook not found — injection may not work"

# ── Step 6: Generate and apply MySQL manifest ──────────────────────────────────
title "Step 6 — Deploying MySQL"

# Generate MySQL manifest inline with correct Vault Agent annotations.
#
# KEY ANNOTATION: vault.hashicorp.com/service
#   This overrides the injector's default AGENT_INJECT_VAULT_ADDR.
#   Without it, the Vault Agent init container uses whatever address
#   the injector was configured with at startup — which may be wrong.
#   Setting it explicitly to the in-cluster service DNS guarantees
#   the agent can reach Vault regardless of injector configuration.
#
# vault.hashicorp.com/agent-inject-secret-db-root:
#   Tells the agent to read secret/data/mysql from Vault and render it
#   as a file at /vault/secrets/db-root inside the pod.
#
# vault.hashicorp.com/agent-inject-template-db-root:
#   Custom template that renders the secret as shell-sourceable exports.
#   MySQL container does: source /vault/secrets/db-root
#   This sets MYSQL_ROOT_PASSWORD and MYSQL_PASSWORD at startup.

mkdir -p database

cat > database/mysql-deployment.yaml << YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: ${NAMESPACE}
  labels:
    app: mysql
spec:
  serviceName: mysql-service
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
      annotations:
        # ── Vault Agent Injector annotations ──────────────────────────────────
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "mysql-role"

        # CRITICAL: explicit in-cluster Vault service address.
        # Overrides injector default — agent connects here from inside pod.
        vault.hashicorp.com/service: "${VAULT_K8S_ADDR}"

        # Read the KV-v2 API path and write to /vault/secrets/db-root
        vault.hashicorp.com/agent-inject-secret-db-root: "secret/data/mysql"

        # Render as shell-sourceable env vars
        vault.hashicorp.com/agent-inject-template-db-root: |
          {{- with secret "secret/data/mysql" -}}
          export MYSQL_ROOT_PASSWORD="{{ .Data.data.root_password }}"
          export MYSQL_PASSWORD="{{ .Data.data.app_password }}"
          export MYSQL_USER="{{ .Data.data.app_user }}"
          export MYSQL_DATABASE="{{ .Data.data.database }}"
          {{- end }}

        # Log level — set to debug if init container still gets stuck
        vault.hashicorp.com/log-level: "info"

        # Init-only: agent exits after writing secrets (no sidecar running)
        vault.hashicorp.com/agent-pre-populate-only: "true"
    spec:
      serviceAccountName: vault-auth-sa
      initContainers: []
      containers:
        - name: mysql
          image: mysql:8.0
          command:
            - /bin/bash
            - -c
            - |
              # Source Vault-injected credentials before starting MySQL
              if [ -f /vault/secrets/db-root ]; then
                source /vault/secrets/db-root
              else
                echo "ERROR: /vault/secrets/db-root not found" >&2
                exit 1
              fi
              exec docker-entrypoint.sh mysqld
          ports:
            - containerPort: 3306
              name: mysql
          env:
            # These are overridden by sourcing /vault/secrets/db-root above.
            # Set here as non-empty placeholders so MySQL entrypoint doesn't
            # complain about missing required variables before source runs.
            - name: MYSQL_ROOT_PASSWORD
              value: "placeholder-overridden-by-vault"
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
            - name: mysql-config
              mountPath: /etc/mysql/conf.d
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            exec:
              command:
                - /bin/bash
                - -c
                - "mysqladmin ping -h localhost -u root -p\${MYSQL_ROOT_PASSWORD} 2>/dev/null"
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            exec:
              command:
                - /bin/bash
                - -c
                - "mysqladmin ping -h localhost -u root -p\${MYSQL_ROOT_PASSWORD} 2>/dev/null"
            initialDelaySeconds: 60
            periodSeconds: 15
            failureThreshold: 4
      volumes:
        - name: mysql-config
          configMap:
            name: mysql-config
  volumeClaimTemplates:
    - metadata:
        name: mysql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard-rwo
        resources:
          requests:
            storage: 10Gi
YAML

# Generate supporting manifests if not present
if [ ! -f database/mysql-configmap.yaml ]; then
cat > database/mysql-configmap.yaml << YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-config
  namespace: ${NAMESPACE}
data:
  my.cnf: |
    [mysqld]
    character-set-server = utf8mb4
    collation-server     = utf8mb4_unicode_ci
    max_connections      = 200
    innodb_buffer_pool_size = 128M
YAML
fi

if [ ! -f database/mysql-service.yaml ]; then
cat > database/mysql-service.yaml << YAML
apiVersion: v1
kind: Service
metadata:
  name: mysql-service
  namespace: ${NAMESPACE}
  labels:
    app: mysql
spec:
  clusterIP: None
  ports:
    - port: 3306
      targetPort: 3306
      name: mysql
  selector:
    app: mysql
YAML
fi

# Delete existing stuck pod if present so new manifest takes effect cleanly
STUCK_POD=$(kubectl get pod mysql-0 -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ -n "$STUCK_POD" ] && [ "$STUCK_POD" != "Running" ]; then
  warn "Deleting stuck MySQL pod (phase=$STUCK_POD) so updated manifest applies..."
  kubectl delete pod mysql-0 -n "$NAMESPACE" --grace-period=10 2>/dev/null || true
  kubectl delete statefulset mysql -n "$NAMESPACE" --grace-period=10 2>/dev/null || true
  sleep 5
fi

log "Applying MySQL ConfigMap..."
kubectl apply -f database/mysql-configmap.yaml -n "$NAMESPACE"

log "Applying MySQL StatefulSet (with correct Vault Agent annotations)..."
kubectl apply -f database/mysql-deployment.yaml

log "Applying MySQL Service..."
kubectl apply -f database/mysql-service.yaml

# ── Step 7: Wait for MySQL Ready ──────────────────────────────────────────────
title "Step 7 — Waiting for MySQL to be Ready"

log "Vault Agent init container will:"
log "  1. Connect to $VAULT_K8S_ADDR (in-cluster)"
log "  2. Authenticate via vault-auth-sa JWT → mysql-role"
log "  3. Read secret/data/mysql → write /vault/secrets/db-root"
log "  4. MySQL sources that file for credentials"

ELAPSED=0
MYSQL_READY=false
LAST_INIT_LOG_DUMP=0

while [ "$ELAPSED" -lt 300 ]; do
  PHASE=$(kubectl get pod -n "$NAMESPACE" -l app=mysql \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")

  INIT_READY=$(kubectl get pod -n "$NAMESPACE" -l app=mysql \
    -o jsonpath='{.items[0].status.initContainerStatuses[*].ready}' 2>/dev/null || echo "")

  READY=$(kubectl get pod -n "$NAMESPACE" -l app=mysql \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

  if [ "$READY" = "true" ]; then
    MYSQL_READY=true
    log "MySQL pod is Ready ✓"
    break
  fi

  # Dump init container logs every 60s so we can see what agent is doing
  if [ "$ELAPSED" -gt 0 ] && [ $((ELAPSED - LAST_INIT_LOG_DUMP)) -ge 60 ]; then
    warn "Vault Agent init container logs (last 15 lines):"
    kubectl logs -n "$NAMESPACE" -l app=mysql \
      -c vault-agent-init --tail=15 2>/dev/null || \
    kubectl logs -n "$NAMESPACE" -l app=mysql \
      --all-containers --tail=15 2>/dev/null || true
    LAST_INIT_LOG_DUMP=$ELAPSED
  fi

  # Detect crash
  CRASH_REASON=$(kubectl get pod -n "$NAMESPACE" -l app=mysql \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' \
    2>/dev/null || true)
  if [ "$CRASH_REASON" = "CrashLoopBackOff" ]; then
    warn "MySQL CrashLoopBackOff — logs:"
    kubectl logs -n "$NAMESPACE" -l app=mysql -c vault-agent-init --tail=30 2>/dev/null || true
    kubectl logs -n "$NAMESPACE" -l app=mysql -c mysql --tail=30 2>/dev/null || true
    fail "MySQL pod crashed. Check Vault connectivity and secret path."
  fi

  warn "[${ELAPSED}s] Phase=$PHASE  InitReady=${INIT_READY:-?}  Ready=$READY"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

if ! $MYSQL_READY; then
  warn "MySQL not Ready after ${ELAPSED}s. Collecting diagnostics..."
  echo ""
  warn "=== Pod description ==="
  kubectl describe pod -n "$NAMESPACE" -l app=mysql | tail -40 || true
  echo ""
  warn "=== Vault Agent init container logs ==="
  kubectl logs -n "$NAMESPACE" -l app=mysql -c vault-agent-init 2>/dev/null || \
  kubectl logs -n "$NAMESPACE" -l app=mysql --all-containers 2>/dev/null || true
  echo ""
  warn "=== Verify Vault agent can reach in-cluster service ==="
  warn "Run: kubectl run -it --rm debug --image=curlimages/curl --restart=Never \\"
  warn "     -- curl -s ${VAULT_K8S_ADDR}/v1/sys/health"
  fail "MySQL pod did not become Ready. See diagnostics above."
fi

# ── Step 8: Verify ─────────────────────────────────────────────────────────────
title "Step 8 — Verification"

log "MySQL pod status:"
kubectl get pods -n "$NAMESPACE" -l app=mysql -o wide

log "MySQL service:"
kubectl get svc mysql-service -n "$NAMESPACE" 2>/dev/null || true

log "MySQL PVC:"
kubectl get pvc -n "$NAMESPACE" 2>/dev/null | grep mysql || true

echo ""
log "✅ MySQL deployed and Ready!"
log "Next step: bash scripts/deploy-k8s.sh"
