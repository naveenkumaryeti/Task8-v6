# 🚀 Enterprise-Grade Kubernetes Deployment on GKE

> Production-grade microservices on Google Kubernetes Engine with GitHub Actions CI/CD,
> Google Artifact Registry, and HashiCorp Vault secret management.

---

## 📐 Architecture Overview

```
Internet
    │
    ▼
GCP Load Balancer
    │
    ▼
NGINX Ingress Controller  (TLS termination, rate limiting)
    │
    ▼
frontend-service (ClusterIP → Nginx pods × 2)
    │
    ├── Static assets served directly
    │
    └── /api/* → backend-service (ClusterIP → Node.js pods × 3)
                        │
                        └── mysql-service (ClusterIP → MySQL StatefulSet × 1)

HashiCorp Vault (separate namespace)
    └── Vault Agent Injector → injects secrets into backend + mysql pods
```

---

## 🗂️ Project Structure

```
project/
├── frontend/                   # Nginx static frontend
│   ├── Dockerfile              # Multi-stage: node builder → nginx:alpine
│   ├── nginx.conf              # Reverse proxy config
│   ├── package.json
│   └── src/index.html          # Frontend application
│
├── backend/                    # Node.js REST API
│   ├── Dockerfile              # Multi-stage: deps → production (non-root)
│   ├── package.json
│   ├── jest.config.js
│   ├── .eslintrc.json
│   └── src/
│       ├── server.js           # Express app with graceful shutdown
│       └── server.test.js      # Jest unit tests
│
├── database/                   # MySQL resources
│   ├── init.sql                # Schema + seed data
│   ├── mysql-configmap.yaml    # MySQL config + init script
│   ├── mysql-deployment.yaml   # StatefulSet with Vault injection
│   ├── mysql-service.yaml      # ClusterIP (internal only)
│   └── mysql-pvc.yaml          # 20Gi SSD PVC (standard-rwo)
│
├── vault/                      # HashiCorp Vault
│   ├── vault-install.yaml      # Helm values for Vault
│   ├── vault-auth.yaml         # Kubernetes auth + ServiceAccount
│   ├── vault-policy.hcl        # Least-privilege ACL policies
│   ├── vault-agent-injector.yaml
│   └── secrets-config.yaml     # Secret path documentation
│
├── k8s/                        # Application Kubernetes manifests
│   ├── namespace.yaml          # production namespace
│   ├── configmap.yaml          # Non-sensitive app config
│   ├── nginx-configmap.yaml    # Nginx config as ConfigMap
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml   # LoadBalancer (external)
│   ├── backend-deployment.yaml # 3 replicas, Vault-injected secrets
│   ├── backend-service.yaml    # ClusterIP (internal)
│   ├── ingress.yaml            # NGINX Ingress + TLS
│   └── hpa.yaml               # HPA + PodDisruptionBudgets
│
├── scripts/                    # Automation scripts
│   ├── cluster-setup.sh        # Create GKE cluster
│   ├── artifact-registry-setup.sh
│   ├── docker-auth.sh
│   ├── build-images.sh
│   ├── push-images.sh
│   ├── vault-secrets.sh        # Seed Vault secrets
│   ├── deploy-database.sh
│   ├── deploy-vault.sh
│   ├── deploy-k8s.sh
│   ├── rolling-update.sh       # Zero-downtime updates + auto-rollback
│   ├── scale-app.sh
│   ├── verify-deployment.sh    # Comprehensive health checks
│   └── cleanup.sh
│
├── .github/workflows/
│   ├── ci.yml                  # Build → Test → Scan → Push
│   └── cd.yml                  # Deploy to GKE → Verify
│
├── docker-compose.yml          # Local dev environment
├── .gitignore
└── README.md
```

---

## ⚡ Quick Start (Full Deployment)

### Prerequisites

```bash
# Install required tools
brew install google-cloud-sdk kubectl helm vault  # macOS
# or follow official docs for Linux

# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Step-by-Step Deployment

```bash
# 1. Create GKE cluster
bash scripts/cluster-setup.sh

# 2. Create Artifact Registry
bash scripts/artifact-registry-setup.sh

# 3. Authenticate Docker
bash scripts/docker-auth.sh

# 4. Build Docker images
bash scripts/build-images.sh 1.0.0

# 5. Push to Artifact Registry
bash scripts/push-images.sh 1.0.0

# 6. Deploy and configure Vault
bash scripts/deploy-vault.sh
# Then unseal manually (see Vault section below)

# 7. Seed secrets into Vault
VAULT_TOKEN=<root-token> bash scripts/vault-secrets.sh

# 8. Deploy MySQL
bash scripts/deploy-database.sh

# 9. Deploy application
bash scripts/deploy-k8s.sh 1.0.0

# 10. Verify everything
bash scripts/verify-deployment.sh
```

---

## 🔐 Secret Management (HashiCorp Vault)

### How it works

```
Pod starts
    │
    ▼
Vault Agent Injector (init container)
    │ reads: /var/run/secrets/kubernetes.io/serviceaccount/token
    │ authenticates with Vault Kubernetes auth
    ▼
Vault returns temporary token
    │
    ▼
Agent fetches secrets from:
    secret/data/app   → JWT_SECRET, SESSION_SECRET
    secret/data/mysql → DB_PASSWORD, DB_USER
    │
    ▼
Secrets written to: /vault/secrets/app-creds (tmpfs — never hits disk)
    │
    ▼
Main container sources the file:
    source /vault/secrets/app-creds
    exec node src/server.js
```

### Vault secret paths

| Path | Contents |
|------|----------|
| `secret/data/mysql` | root_password, app_password, app_user, host, port, database |
| `secret/data/app` | jwt_secret, session_secret, api_key |
| `secret/data/ci` | gke_sa_key (for CI/CD) |

### First-time Vault initialization

```bash
# After deploy-vault.sh completes:

# 1. Get Vault pod name
VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}')

# 2. Initialize (save the output SECURELY)
kubectl exec $VAULT_POD -n vault -- vault operator init \
  -key-shares=5 \
  -key-threshold=3

# 3. Unseal (run 3 times with 3 different keys from init output)
kubectl exec $VAULT_POD -n vault -- vault operator unseal <KEY_1>
kubectl exec $VAULT_POD -n vault -- vault operator unseal <KEY_2>
kubectl exec $VAULT_POD -n vault -- vault operator unseal <KEY_3>

# 4. Seed secrets
export VAULT_ADDR=http://localhost:8200
kubectl port-forward svc/vault -n vault 8200:8200 &
export VAULT_TOKEN=<root-token-from-init>
bash scripts/vault-secrets.sh
```

> **Production:** Configure [GCP KMS auto-unseal](https://developer.hashicorp.com/vault/docs/configuration/seal/gcpckms) in `vault/vault-install.yaml` — eliminates manual unseal steps.

---

## 🔄 CI/CD Pipeline

### CI Workflow (`.github/workflows/ci.yml`)

```
Push to main/develop
        │
        ▼
  ┌─────────────┐
  │   Validate   │  npm ci → lint → jest --coverage
  └──────┬──────┘
         │
         ▼
  ┌─────────────────────┐
  │  Build Docker Images │  BuildKit multi-stage (cached layers)
  │  frontend + backend  │
  └──────────┬──────────┘
             │
             ▼
  ┌──────────────────┐
  │  Trivy Security  │  HIGH/CRITICAL CVEs → fail build
  │  Scan both images│  Results → GitHub Security tab
  └──────┬───────────┘
         │ (only if scan passes)
         ▼
  ┌──────────────────────────────┐
  │  Push to Artifact Registry   │
  │  asia-south1-docker.pkg.dev  │
  └──────────────────────────────┘
```

### CD Workflow (`.github/workflows/cd.yml`)

```
CI succeeds on main
        │
        ▼
  ┌────────────┐
  │    Gate    │  Verify CI conclusion == 'success'
  └─────┬──────┘
        │
        ▼
  ┌─────────────────────────────────┐
  │  kubectl set image deployment   │  Rolling update (maxUnavailable=0)
  │  frontend + backend             │
  └──────────┬──────────────────────┘
             │
             ▼
  ┌──────────────────────┐
  │  kubectl rollout      │  Wait 180s for complete rollout
  │  status --timeout     │  Auto-rollback if fails
  └──────────┬────────────┘
             │
             ▼
  ┌──────────────────────┐
  │  HTTP health check   │  curl /health → 200 required
  │  Auto-rollback if ≠  │
  └──────────────────────┘
```

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `GCP_PROJECT_ID` | GCP project ID |
| `GCP_SA_KEY` | Base64-encoded service account JSON |
| `GCP_REGION` | e.g. `asia-south1` |
| `GKE_CLUSTER_NAME` | e.g. `prod-cluster` |
| `GKE_ZONE` | e.g. `asia-south1-a` |
| `GAR_REPO_NAME` | e.g. `prod-repo` |

```bash
# Create and encode service account key
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions CI/CD"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/container.developer"

gcloud iam service-accounts keys create /tmp/sa-key.json \
  --iam-account="github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Add to GitHub Secrets as GCP_SA_KEY:
base64 -i /tmp/sa-key.json | pbcopy   # macOS — paste into GitHub Secret
rm /tmp/sa-key.json
```

---

## 🔁 Rolling Updates

```bash
# Update a specific component
bash scripts/rolling-update.sh backend 1.2.0
bash scripts/rolling-update.sh frontend 1.2.0
bash scripts/rolling-update.sh all 1.2.0

# Manual rollback (if needed)
kubectl rollout undo deployment/backend  -n production
kubectl rollout undo deployment/frontend -n production

# View rollout history
kubectl rollout history deployment/backend -n production
```

---

## 📈 Scaling

```bash
# Manual scaling (HPA overrides this eventually)
bash scripts/scale-app.sh backend 5
bash scripts/scale-app.sh frontend 3

# View HPA status
kubectl get hpa -n production

# HPA scaling rules:
#   Backend:  min=3, max=10, CPU>70% or Memory>80%
#   Frontend: min=2, max=6,  CPU>75%
```

---

## 🩺 Health Probes

| Component | Liveness Probe | Readiness Probe |
|-----------|---------------|-----------------|
| Frontend | `GET /health` (Nginx) | `GET /health` |
| Backend | `GET /api/ping` (**NO DB check**) | `GET /api/health` (validates DB) |
| MySQL | `mysqladmin ping` | `mysql -e 'SELECT 1'` |

> **Critical rule:** Liveness probes must NEVER check external dependencies (DB, cache, APIs).
> If the DB goes down, liveness should NOT restart the pod — that causes cascade restarts.
> Only readiness should check DB connectivity, which stops traffic without restarting pods.

---

## 🐳 Local Development

```bash
# Start everything locally
docker-compose up -d

# Access points:
#   Frontend: http://localhost:80
#   Backend API: http://localhost:3000
#   Vault UI: http://localhost:8200 (token: dev-root-token)
#   MySQL: localhost:3306 (user: appuser, pass: devpass123)

# View logs
docker-compose logs -f backend

# Stop
docker-compose down        # Keep volumes (data preserved)
docker-compose down -v     # Remove volumes (data lost)
```

---

## 🔧 Useful kubectl Commands

```bash
# Pod management
kubectl get pods -n production -o wide
kubectl describe pod <pod-name> -n production
kubectl logs <pod-name> -n production --tail=100 -f
kubectl exec -it <pod-name> -n production -- sh

# Deployment ops
kubectl rollout status deployment/backend -n production
kubectl rollout history deployment/backend -n production
kubectl rollout undo deployment/backend -n production

# Scaling
kubectl scale deployment/backend --replicas=5 -n production

# ConfigMap update (triggers pod restart via checksum annotation)
kubectl edit configmap app-config -n production
kubectl rollout restart deployment/backend -n production

# Port forwarding (debug without external exposure)
kubectl port-forward svc/backend-service 3000:3000 -n production
kubectl port-forward svc/vault 8200:8200 -n vault

# Resource usage
kubectl top pods -n production
kubectl top nodes
```

---

## 🏗️ Key Architecture Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Secret management | HashiCorp Vault | Zero hardcoded secrets anywhere; dynamic injection |
| MySQL deployment type | StatefulSet | Stable pod name, stable PVC binding |
| Liveness probe for backend | `/api/ping` (no DB) | Prevents cascade restarts during DB maintenance |
| `maxUnavailable: 0` | Always 0 | Zero-downtime rolling updates |
| `preStop: sleep 5` | 5s sleep before SIGTERM | Kubernetes removes pod from endpoints before process stops |
| Storage class | `standard-rwo` | GKE SSD, ReadWriteOnce — correct for single-writer MySQL |
| Image registry | Google Artifact Registry | Native GKE integration, IAM-based access, regional |
| Vault Agent mode | Injector (sidecar) | No app code changes needed; transparent secret delivery |

---

## 🧹 Cleanup

```bash
# Remove app only (keep namespace + MySQL data)
bash scripts/cleanup.sh

# Remove everything including MySQL data (DESTRUCTIVE)
bash scripts/cleanup.sh --full

# Delete the entire GKE cluster
gcloud container clusters delete prod-cluster --zone=asia-south1-a
```

---

## 📋 Environment Variables Reference

### Backend (set via ConfigMap + Vault)

| Variable | Source | Description |
|----------|--------|-------------|
| `NODE_ENV` | ConfigMap | `production` |
| `PORT` | ConfigMap | `3000` |
| `DB_HOST` | ConfigMap | `mysql-service` |
| `DB_PORT` | ConfigMap | `3306` |
| `DB_NAME` | ConfigMap | `appdb` |
| `DB_USER` | **Vault** | `appuser` |
| `DB_PASSWORD` | **Vault** | MySQL app user password |
| `JWT_SECRET` | **Vault** | JWT signing key |
| `SESSION_SECRET` | **Vault** | Express session secret |

---

*Built for production. Tested for zero-downtime. Secured with Vault.*

---

## 🌐 Domain Mapping & DNS Configuration

> **Target Domain:** `enterprise-app.gt.tc`
> **Protocol:** HTTPS (TLS via cert-manager + Let's Encrypt)
> **Hosting Platform:** GKE + NGINX Ingress Controller + GCP External Load Balancer

This section explains — step by step — how to map the custom domain `enterprise-app.gt.tc` to the running GKE application, configure DNS records, validate propagation using Google Public DNS, and verify the full HTTPS stack.

---

### 📐 Domain Mapping Architecture

The request path from a user's browser to your application involves four hops:

```
User's Browser
      │
      │  DNS Lookup: enterprise-app.gt.tc → <GCP Load Balancer IP>
      ▼
Google Public DNS (8.8.8.8 / 8.8.4.4)
      │
      │  Returns: A Record → e.g. 34.93.120.45
      ▼
GCP External Load Balancer  (provisioned automatically by GKE LoadBalancer Service)
      │
      │  Port 443 → TLS termination at Ingress Controller
      │  Port 80  → Redirect to HTTPS (ssl-redirect: "true")
      ▼
NGINX Ingress Controller  (running inside GKE cluster, namespace: production)
      │
      │  Host-based routing:  enterprise-app.gt.tc → frontend-service
      ▼
frontend-service  (ClusterIP, port 80)
      │
      ├── Static assets (HTML/CSS/JS)  served by Nginx pods
      │
      └── /api/* requests  → backend-service:3000 → Node.js pods
                                        │
                                        └── mysql-service:3306 → MySQL StatefulSet

cert-manager (cluster-wide)
      └── Auto-provisions Let's Encrypt TLS certificate
          Stores in Kubernetes Secret: app-tls-cert
          Auto-renews 30 days before expiry
```

---

### Step 1 — Get the External Load Balancer IP

After running `bash scripts/deploy-k8s.sh`, GKE provisions an external IP for the NGINX Ingress Controller. Retrieve it:

```bash
# Wait for the external IP to be assigned (can take 2–5 minutes)
kubectl get svc ingress-nginx-controller -n ingress-nginx -w

# Expected output (once provisioned):
# NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)
# ingress-nginx-controller   LoadBalancer   10.108.3.45   34.93.120.45     80:31xxx/TCP,443:32xxx/TCP

# Save the EXTERNAL-IP for the DNS step below
EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Your Load Balancer IP: $EXTERNAL_IP"
```

> **Note:** If you used the `frontend-service` LoadBalancer directly (without NGINX Ingress):
> ```bash
> kubectl get svc frontend-service -n production -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
> ```

---

### Step 2 — Configure DNS Records

Log into your DNS registrar or DNS management panel for the `gt.tc` domain.

#### Option A — A Record (Recommended for Root Domains)

Use this when mapping directly to a static IP address from the GCP Load Balancer:

| Field       | Value                            | Description                          |
|-------------|----------------------------------|--------------------------------------|
| **Type**    | `A`                              | Maps hostname → IPv4 address         |
| **Name**    | `enterprise-app`                 | Subdomain (under `gt.tc`)            |
| **Value**   | `34.93.120.45`                   | Your GCP Load Balancer External IP   |
| **TTL**     | `300` (5 minutes)                | Low TTL during initial setup         |

**DNS Zone File Format:**
```
enterprise-app.gt.tc.   300   IN   A   34.93.120.45
```

#### Option B — CNAME Record (For Cloud Platforms with DNS Names)

Use this if your cloud platform provides a DNS name instead of a static IP (common with GCP Global Load Balancers or if using a CDN):

| Field       | Value                                          | Description                          |
|-------------|------------------------------------------------|--------------------------------------|
| **Type**    | `CNAME`                                        | Alias pointing to another hostname   |
| **Name**    | `enterprise-app`                               | Subdomain (under `gt.tc`)            |
| **Value**   | `your-lb.asia-south1.cloudapp.gcp.com`         | Cloud-provided DNS hostname          |
| **TTL**     | `300`                                          | Low TTL during initial setup         |

**DNS Zone File Format:**
```
enterprise-app.gt.tc.   300   IN   CNAME   your-lb.asia-south1.cloudapp.gcp.com.
```

> **Which to use?** For this GKE deployment on GCP with a static external IP assigned by the LoadBalancer service, **use an A Record** (Option A). The GCP External Load Balancer provides a stable IPv4 address.

#### Complete DNS Configuration Example

```
; gt.tc DNS Zone — example configuration
; Replace 34.93.120.45 with your actual Load Balancer IP

; Subdomain for the enterprise application
enterprise-app.gt.tc.   300   IN   A      34.93.120.45

; Optional: www variant (redirects handled by NGINX Ingress)
www.enterprise-app.gt.tc.  300  IN  CNAME  enterprise-app.gt.tc.

; Optional: CAA record to restrict which CAs can issue TLS certs
enterprise-app.gt.tc.   300   IN   CAA    0 issue "letsencrypt.org"
```

---

### Step 3 — Update the Kubernetes Ingress Manifest

The `k8s/ingress.yaml` uses placeholder hostnames. Update them to reflect the real domain before applying:

```yaml
# k8s/ingress.yaml — update the tls and rules sections

spec:
  tls:
    - hosts:
        - enterprise-app.gt.tc          # ← Replace yourdomain.com
      secretName: app-tls-cert          # cert-manager creates this automatically

  rules:
    - host: enterprise-app.gt.tc        # ← Replace yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-service
                port:
                  name: http
```

Apply the updated Ingress:

```bash
kubectl apply -f k8s/ingress.yaml -n production

# Verify the Ingress picked up the hostname
kubectl get ingress app-ingress -n production -o wide
# Expected:
# NAME          CLASS   HOSTS                    ADDRESS         PORTS     AGE
# app-ingress   nginx   enterprise-app.gt.tc     34.93.120.45   80, 443   5m
```

Also update `k8s/configmap.yaml` to whitelist the real domain for CORS:

```yaml
# k8s/configmap.yaml — update ALLOWED_ORIGINS
data:
  ALLOWED_ORIGINS: "https://enterprise-app.gt.tc"
```

```bash
kubectl apply -f k8s/configmap.yaml -n production
# Restart backend to pick up new env var
kubectl rollout restart deployment/backend -n production
```

---

### Step 4 — Install cert-manager (TLS Certificate Automation)

cert-manager automatically provisions and renews Let's Encrypt TLS certificates so your domain is served over HTTPS without manual intervention.

#### 4a. Install cert-manager

```bash
# Install cert-manager CRDs and controller
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Verify cert-manager pods are running (takes ~60 seconds)
kubectl get pods -n cert-manager
# Expected:
# NAME                                      READY   STATUS    RESTARTS
# cert-manager-xxxx                         1/1     Running   0
# cert-manager-cainjector-xxxx              1/1     Running   0
# cert-manager-webhook-xxxx                 1/1     Running   0
```

#### 4b. Create a ClusterIssuer for Let's Encrypt

```bash
# Create the ClusterIssuer (save this as cert-manager-issuer.yaml)
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # Let's Encrypt production endpoint
    server: https://acme-v02.api.letsencrypt.org/directory
    # Replace with your actual email address for expiry notifications
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx    # Matches kubernetes.io/ingress.class in ingress.yaml
EOF

# Verify the ClusterIssuer is ready
kubectl get clusterissuer letsencrypt-prod
# Expected:
# NAME               READY   AGE
# letsencrypt-prod   True    30s
```

#### 4c. Verify Certificate Issuance

Once the Ingress is applied with the correct domain, cert-manager automatically:
1. Creates a `Certificate` resource targeting `enterprise-app.gt.tc`
2. Completes an HTTP-01 ACME challenge via Let's Encrypt
3. Stores the signed certificate in the Kubernetes Secret `app-tls-cert`

```bash
# Watch certificate status (may take 1–3 minutes)
kubectl get certificate -n production -w
# Expected:
# NAME           READY   SECRET         AGE
# app-tls-cert   True    app-tls-cert   2m

# Inspect certificate details
kubectl describe certificate app-tls-cert -n production
# Look for: Status: Certificate is up to date and has not expired

# View ACME challenge (if still in progress)
kubectl get certificaterequest -n production
kubectl get order -n production
kubectl get challenge -n production
```

---

### Step 5 — DNS Propagation & Validation

DNS changes do not take effect instantly. Propagation can take anywhere from a few seconds (with low TTL like 300s) to 48 hours (with high TTL or slow resolvers). Google Public DNS (`8.8.8.8` / `8.8.4.4`) typically reflects changes within minutes.

#### What is DNS Propagation?

When you update an A Record in your DNS registrar, the change must spread from your registrar's authoritative name servers to DNS resolvers worldwide (recursive resolvers like `8.8.8.8`). During propagation, some users may resolve the old IP while others get the new one — this is normal and temporary.

#### 5a. Validate from Linux/macOS

```bash
# ── Using nslookup ──────────────────────────────────────────────────────────

# Query Google's primary DNS server
nslookup enterprise-app.gt.tc 8.8.8.8
# Expected output:
# Server:     8.8.8.8
# Address:    8.8.8.8#53
#
# Non-authoritative answer:
# Name:    enterprise-app.gt.tc
# Address: 34.93.120.45      ← Must match your Load Balancer IP

# Query Google's secondary DNS server
nslookup enterprise-app.gt.tc 8.8.4.4
# Expected output: same IP address as above

# ── Using dig (more detailed output) ──────────────────────────────────────

# Primary DNS
dig @8.8.8.8 enterprise-app.gt.tc
# Look for the ANSWER SECTION:
# enterprise-app.gt.tc.  300  IN  A  34.93.120.45

# Secondary DNS
dig @8.8.4.4 enterprise-app.gt.tc
# Same IP expected

# Short output format (just the IP)
dig @8.8.8.8 enterprise-app.gt.tc +short
# Expected: 34.93.120.45

# Check TTL remaining
dig @8.8.8.8 enterprise-app.gt.tc +ttlid
```

#### 5b. Validate from Windows

```powershell
# Query Google's primary DNS server
nslookup enterprise-app.gt.tc 8.8.8.8
# Expected:
# Server:  dns.google
# Address: 8.8.8.8
#
# Non-authoritative answer:
# Name:    enterprise-app.gt.tc
# Address: 34.93.120.45

# Query Google's secondary DNS server
nslookup enterprise-app.gt.tc 8.8.4.4
# Expected: same IP address

# PowerShell alternative
Resolve-DnsName -Name enterprise-app.gt.tc -Server 8.8.8.8
# Expected output:
# Name                           Type  TTL   Section   IPAddress
# enterprise-app.gt.tc           A     300   Answer    34.93.120.45
```

#### 5c. Cross-Region Propagation Check

DNS propagation varies by region. Use online tools to verify global reach:

```bash
# Use dig with a trace to follow the full delegation chain
dig @8.8.8.8 enterprise-app.gt.tc +trace

# Check from authoritative nameserver directly (skip cache)
# First, find the authoritative NS for gt.tc
dig @8.8.8.8 gt.tc NS +short
# Then query the authoritative server directly
dig @<authoritative-ns-from-above> enterprise-app.gt.tc A
```

---

### Step 6 — Verify Application Accessibility

#### 6a. HTTPS Access

Once DNS has propagated and the TLS certificate is issued:

```bash
# Full HTTPS verification
curl -v https://enterprise-app.gt.tc
# Expected:
#   * SSL certificate verify ok
#   * subject: CN=enterprise-app.gt.tc
#   * issuer: C=US, O=Let's Encrypt, CN=R3
#   < HTTP/2 200

# Test health endpoint
curl -s https://enterprise-app.gt.tc/health
# Expected: {"status":"healthy","service":"frontend"}

# Test API endpoint
curl -s https://enterprise-app.gt.tc/api/ping
# Expected: {"status":"ok"}  or similar ping response

curl -s https://enterprise-app.gt.tc/api/health
# Expected: {"status":"ok","db":"connected"}  (readiness probe endpoint)
```

#### 6b. HTTP → HTTPS Redirect Verification

The Ingress forces HTTPS (`ssl-redirect: "true"`). Confirm the redirect works:

```bash
curl -Lv http://enterprise-app.gt.tc
# Expected: HTTP 301 → https://enterprise-app.gt.tc → HTTP 200
# Look for:  < HTTP/1.1 301 Moved Permanently
#            < Location: https://enterprise-app.gt.tc/
```

#### 6c. SSL/TLS Certificate Verification

```bash
# Inspect the certificate details
echo | openssl s_client -connect enterprise-app.gt.tc:443 -servername enterprise-app.gt.tc 2>/dev/null \
  | openssl x509 -noout -text | grep -E "Subject|Issuer|Not (Before|After)"
# Expected:
#   Subject: CN=enterprise-app.gt.tc
#   Issuer:  C=US, O=Let's Encrypt, CN=R3
#   Not Before: [date of issuance]
#   Not After:  [date ~90 days later]

# Check cert expiry date
echo | openssl s_client -connect enterprise-app.gt.tc:443 2>/dev/null \
  | openssl x509 -noout -enddate
# Expected:
#   notAfter=Aug 28 12:00:00 2026 GMT
```

#### 6d. Full Stack Verification Script

The existing `scripts/verify-deployment.sh` already checks pod health and internal IP. Add this domain verification block at the end:

```bash
# Append to scripts/verify-deployment.sh or run standalone:

DOMAIN="enterprise-app.gt.tc"

echo "── Domain Resolution Check ──"
RESOLVED_IP=$(dig @8.8.8.8 "$DOMAIN" +short | head -1)
echo "Resolved IP from Google DNS: $RESOLVED_IP"

echo "── HTTPS Health Check ──"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/health")
echo "HTTPS /health status: $HTTP_STATUS"
[ "$HTTP_STATUS" = "200" ] && echo "✓ Application is reachable" || echo "✗ Application not reachable"

echo "── TLS Certificate Check ──"
CERT_EXPIRY=$(echo | openssl s_client -connect "$DOMAIN:443" 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null)
echo "Certificate expiry: $CERT_EXPIRY"
```

---

### Step 7 — Expected Outcome

After completing all steps above, the following must hold true:

| Check | Expected Result |
|-------|----------------|
| `nslookup enterprise-app.gt.tc 8.8.8.8` | Returns your GCP Load Balancer IP |
| `nslookup enterprise-app.gt.tc 8.8.4.4` | Returns same IP |
| `https://enterprise-app.gt.tc` | Returns HTTP 200 with valid content |
| `http://enterprise-app.gt.tc` | Redirects to HTTPS (HTTP 301) |
| TLS certificate issuer | Let's Encrypt (via cert-manager) |
| TLS certificate subject | `CN=enterprise-app.gt.tc` |
| `https://enterprise-app.gt.tc/health` | `{"status":"healthy","service":"frontend"}` |
| `https://enterprise-app.gt.tc/api/health` | `{"status":"ok","db":"connected"}` |

---

### 🔧 Troubleshooting

#### Problem: DNS not resolving — `nslookup` returns `NXDOMAIN`

**Cause:** DNS record not yet propagated, or A Record is missing/wrong.

```bash
# Check what the authoritative nameserver returns
dig @8.8.8.8 enterprise-app.gt.tc
# If NXDOMAIN: the record doesn't exist yet in the authoritative server
# If SERVFAIL: check authoritative NS health

# Verify your registrar shows the correct A record
# Log into your DNS control panel and confirm:
#   Type: A
#   Name: enterprise-app
#   Value: <your Load Balancer IP>

# Force-refresh with no-cache query
dig @8.8.8.8 enterprise-app.gt.tc +nocache
```

**Fix:** Re-add the A Record in your DNS panel. If you added it correctly, wait up to 15 minutes and retry.

---

#### Problem: DNS resolves but application returns 502 or 503

**Cause:** Ingress controller is up but the backend pods are not ready, or the Ingress rule doesn't match the hostname.

```bash
# 1. Check Ingress configuration
kubectl get ingress app-ingress -n production -o yaml
# Confirm: spec.rules[0].host == "enterprise-app.gt.tc"

# 2. Check backend pod readiness
kubectl get pods -n production -l app=backend
# All pods should show READY 1/1

# 3. Check Ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50
# Look for errors related to enterprise-app.gt.tc

# 4. Check events
kubectl get events -n production --sort-by='.lastTimestamp' | tail -20
```

**Fix:** Ensure the Ingress `host` field exactly matches the DNS name. Verify backend pods pass their readiness probe (`/api/health`).

---

#### Problem: TLS certificate stuck in "Pending" or "False"

**Cause:** cert-manager cannot complete the HTTP-01 ACME challenge because DNS hasn't propagated yet, or port 80 is blocked.

```bash
# Check certificate status
kubectl describe certificate app-tls-cert -n production
# Look for Events section — it shows the ACME challenge progress

# Check challenges
kubectl get challenges -n production
kubectl describe challenge -n production

# Most common error:
# "Waiting for HTTP-01 challenge propagation: failed to perform self-check..."
# This means Let's Encrypt cannot reach http://enterprise-app.gt.tc/.well-known/acme-challenge/...
```

**Fix:** Ensure:
1. DNS has propagated (A Record resolves to correct IP)
2. Port 80 is open on the GCP firewall (GKE LoadBalancer opens it by default)
3. The Ingress Controller is running: `kubectl get pods -n ingress-nginx`

---

#### Problem: Browser shows "old" cached IP after DNS update

**Cause:** Browser caches DNS responses locally, separate from OS-level DNS cache.

```bash
# ── Linux (systemd-resolved) ──────────────────────────────────────────────
sudo systemd-resolve --flush-caches
# Verify flush:
sudo systemd-resolve --statistics | grep "Cache"

# ── macOS ─────────────────────────────────────────────────────────────────
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
echo "macOS DNS cache flushed"

# ── Windows (PowerShell as Administrator) ─────────────────────────────────
ipconfig /flushdns
# Expected: Successfully flushed the DNS Resolver Cache.
```

**Browser-specific cache clear:**
- **Chrome:** Navigate to `chrome://net-internals/#dns` → click **Clear host cache**
- **Firefox:** Press `Ctrl+Shift+Delete` → select **Cache** → clear
- **Edge:** Navigate to `edge://net-internals/#dns` → click **Clear host cache**

---

#### Problem: Firewall blocking traffic — site unreachable even after DNS propagates

**Cause:** GCP VPC firewall rules might block inbound traffic on ports 80/443.

```bash
# Check GCP firewall rules allow HTTP/HTTPS inbound
gcloud compute firewall-rules list --filter="network=default" \
  --format="table(name,direction,allowed,targetTags)"

# If missing, add rules (GKE usually creates these automatically for LoadBalancer services):
gcloud compute firewall-rules create allow-http-https \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --description="Allow HTTP and HTTPS inbound"

# Verify Load Balancer health backend check
gcloud compute backend-services list --global
gcloud compute backend-services get-health <backend-service-name> --global
```

---

#### Problem: `curl: (60) SSL certificate problem: certificate has expired`

**Cause:** cert-manager failed to renew the Let's Encrypt certificate (valid for 90 days, auto-renewed at 60 days).

```bash
# Check cert-manager logs for renewal errors
kubectl logs -n cert-manager -l app=cert-manager --tail=100 | grep -i "error\|renew\|enterprise-app"

# Force manual renewal
kubectl delete certificate app-tls-cert -n production
# cert-manager will automatically re-create and re-issue

# Monitor renewal
kubectl get certificate -n production -w
```

---

### 📋 DNS Propagation Reference

| DNS Tool | Primary DNS | Secondary DNS | Purpose |
|----------|-------------|---------------|---------|
| `nslookup` | `8.8.8.8` | `8.8.4.4` | Quick resolution check |
| `dig` | `@8.8.8.8` | `@8.8.4.4` | Detailed DNS answer with TTL |
| `host` | `enterprise-app.gt.tc 8.8.8.8` | — | Simple hostname lookup |
| `Resolve-DnsName` (Windows) | `-Server 8.8.8.8` | `-Server 8.8.4.4` | PowerShell-native resolution |

**Typical propagation timeline:**

```
T+0 min   → DNS record added at registrar
T+1 min   → Authoritative NS returns new record
T+5 min   → Google DNS (8.8.8.8) reflects new record
T+15 min  → Most global resolvers have updated
T+4 hrs   → Full global propagation (worst case for TTL=14400)
T+48 hrs  → Maximum possible propagation delay (legacy TTLs)
```

> **Tip:** Set a low TTL (300 seconds) before making DNS changes. After the application is stable, increase TTL to 3600 or 86400 for better caching performance.

---

*Domain mapping verified. Application accessible at `https://enterprise-app.gt.tc`.*
