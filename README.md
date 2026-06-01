# Enterprise-Grade Kubernetes Deployment on GKE

> Production-grade three-tier microservices application deployed on Google Kubernetes Engine (GKE)
> with GitHub Actions CI/CD, Google Artifact Registry, HashiCorp Vault secret management,
> NGINX Ingress Controller, cert-manager TLS, and full automation scripts.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Technology Stack](#technology-stack)
3. [Project Structure](#project-structure)
4. [File-by-File Description](#file-by-file-description)
5. [Prerequisites](#prerequisites)
6. [Environment Variables Reference](#environment-variables-reference)
7. [GitHub Secrets Reference](#github-secrets-reference)
8. [Complete Deployment Guide (Step-by-Step)](#complete-deployment-guide-step-by-step)
   - [Phase 0 — Local Development (Docker Compose)](#phase-0--local-development-docker-compose)
   - [Phase 1 — GKE Cluster Setup](#phase-1--gke-cluster-setup)
   - [Phase 2 — Artifact Registry & Docker Images](#phase-2--artifact-registry--docker-images)
   - [Phase 3 — HashiCorp Vault](#phase-3--hashicorp-vault)
   - [Phase 4 — Database Deployment](#phase-4--database-deployment)
   - [Phase 5 — Application Deployment](#phase-5--application-deployment)
   - [Phase 6 — DNS & TLS Setup](#phase-6--dns--tls-setup)
   - [Phase 7 — Verify Everything](#phase-7--verify-everything)
9. [CI/CD Pipeline](#cicd-pipeline)
10. [Day-2 Operations Scripts](#day-2-operations-scripts)
11. [Cleanup](#cleanup)
12. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet
    │
    ▼
GCP Load Balancer  (external IP)
    │
    ▼
NGINX Ingress Controller  (TLS termination via cert-manager + Let's Encrypt)
    │
    ├── /         → frontend-service  (ClusterIP → Nginx pods × 2)
    │                   └── Serves static HTML/JS
    │
    └── /api/*    → backend-service   (ClusterIP → Node.js pods × 3)
                        │
                        └── mysql-service (ClusterIP → MySQL StatefulSet × 1)

HashiCorp Vault  (namespace: vault)
    └── Vault Agent Injector
            ├── Injects DB credentials into backend pods
            └── Injects root password into MySQL pod

GitHub Actions
    ├── ci.yml  — Build → Test → Trivy Scan → Push to Artifact Registry
    └── cd.yml  — Pull image → Deploy to GKE → Health check → Rollback on failure
```

### Request Flow

1. User hits `https://enterprise-app.duckdns.org`
2. DNS resolves to GCP Load Balancer external IP
3. NGINX Ingress terminates TLS (cert from Let's Encrypt via cert-manager)
4. Static requests (`/`) go to the Nginx frontend pods
5. API requests (`/api/*`) are proxied to Node.js backend pods
6. Backend queries MySQL via internal ClusterIP DNS (`mysql-service:3306`)
7. Secrets (DB password, JWT secret) are never in manifests — Vault Agent injects them as environment variables at pod startup

---

## Technology Stack

| Layer | Technology |
|---|---|
| Container Orchestration | Google Kubernetes Engine (GKE) |
| Cloud Provider | Google Cloud Platform (GCP) — region `asia-south1` |
| Image Registry | Google Artifact Registry |
| Secret Management | HashiCorp Vault (Kubernetes auth + Agent Injector) |
| Frontend | Nginx (static file server + reverse proxy) |
| Backend | Node.js 20 + Express |
| Database | MySQL 8.0 (StatefulSet) |
| Ingress | NGINX Ingress Controller |
| TLS Certificates | cert-manager + Let's Encrypt (HTTP-01 challenge) |
| Autoscaling | Horizontal Pod Autoscaler (HPA) |
| CI/CD | GitHub Actions |
| Local Dev | Docker Compose |

---

## Project Structure

```
Task8-v6/
│
├── frontend/                        # Nginx static frontend
│   ├── Dockerfile                   # Multi-stage: Node builder → nginx:alpine
│   ├── nginx.conf                   # Nginx config: static files + /api proxy
│   ├── .dockerignore
│   ├── package.json
│   └── src/
│       └── index.html               # Frontend HTML/JS application
│
├── backend/                         # Node.js REST API
│   ├── Dockerfile                   # Multi-stage: deps install → production (non-root user)
│   ├── package.json                 # Express, mysql2, helmet, cors, rate-limit
│   ├── jest.config.js               # Jest test configuration
│   ├── .eslintrc.json               # ESLint rules
│   ├── .dockerignore
│   └── src/
│       ├── server.js                # Express app: /api/ping, /api/health, /api/items
│       └── server.test.js           # Jest unit tests
│
├── database/                        # MySQL resources
│   ├── init.sql                     # Schema creation + seed data
│   ├── mysql-configmap.yaml         # MySQL config file + init SQL as ConfigMap
│   ├── mysql-deployment.yaml        # StatefulSet with Vault Agent injection
│   ├── mysql-service.yaml           # ClusterIP service (internal only)
│   └── mysql-pvc.yaml               # 20Gi PersistentVolumeClaim (standard-rwo)
│
├── vault/                           # HashiCorp Vault configuration
│   ├── vault-install.yaml           # Helm values for Vault server + injector
│   ├── vault-auth.yaml              # Kubernetes auth method + ServiceAccount
│   ├── vault-policy.hcl             # Least-privilege ACL policies
│   ├── vault-agent-injector.yaml    # Injector webhook configuration
│   └── secrets-config.yaml          # Secret path documentation
│
├── helm/
│   └── vault-values.yaml            # Vault Helm chart values (resources, storage)
│
├── k8s/                             # Kubernetes manifests (application layer)
│   ├── namespace.yaml               # production namespace + Vault injection label
│   ├── configmap.yaml               # Non-sensitive app config (DB host, CORS, etc.)
│   ├── nginx-configmap.yaml         # Nginx config mounted into frontend pods
│   ├── frontend-deployment.yaml     # 2 replicas, liveness/readiness probes, HPA-ready
│   ├── frontend-service.yaml        # ClusterIP service for frontend
│   ├── backend-deployment.yaml      # 3 replicas, Vault-injected secrets, Downward API
│   ├── backend-service.yaml         # ClusterIP service for backend
│   ├── ingress.yaml                 # NGINX Ingress + TLS + cert-manager annotation
│   └── hpa.yaml                     # HPA + PodDisruptionBudgets for frontend & backend
│
├── cert-manager/
│   └── cluster-issuer.yaml          # Let's Encrypt ClusterIssuer (prod + staging)
│
├── scripts/                         # Automation bash scripts
│   ├── cluster-setup.sh             # Create GKE cluster (quota-aware)
│   ├── artifact-registry-setup.sh   # Create GAR repository + cleanup policies
│   ├── docker-auth.sh               # Authenticate Docker with GAR
│   ├── build-images.sh              # Build frontend + backend Docker images
│   ├── push-images.sh               # Tag + push images to GAR
│   ├── deploy-vault.sh              # Install Vault via Helm + initialize + unseal
│   ├── vault-secrets.sh             # Configure Vault Kubernetes auth + write secrets
│   ├── deploy-database.sh           # Deploy MySQL StatefulSet with correct Vault annotations
│   ├── deploy-k8s.sh                # Deploy frontend + backend + ingress
│   ├── dns-setup.sh                 # Get LB IP, wait for DNS propagation, apply ingress
│   ├── dns-validate.sh              # Full DNS + HTTPS + TLS validation checks
│   ├── verify-deployment.sh         # Comprehensive health check across all components
│   ├── rolling-update.sh            # Zero-downtime image update + auto-rollback
│   ├── scale-app.sh                 # Manual scale frontend/backend replicas
│   └── cleanup.sh                   # Delete resources (safe + full modes)
│
├── .github/
│   └── workflows/
│       ├── ci.yml                   # CI: Lint → Test → Trivy scan → Push to GAR
│       └── cd.yml                   # CD: Deploy to GKE → Verify → Rollback on failure
│
├── docker-compose.yml               # Local dev: frontend + backend + mysql + vault
├── vault-init-keys.json             # Auto-generated by deploy-vault.sh (Vault unseal keys)
├── ca.crt                           # Kubernetes cluster CA certificate
└── .gitignore
```

---

## File-by-File Description

### Application Files

#### `frontend/src/index.html`
The complete frontend single-page application. Makes API calls to `/api/health`, `/api/items`, and `/api/ping` to demonstrate the full stack is working.

#### `frontend/nginx.conf`
Nginx configuration that:
- Serves static files from `/usr/share/nginx/html`
- Proxies all `/api/*` requests to the backend service
- Sets security headers and enables gzip compression
- This same config is also stored as `k8s/nginx-configmap.yaml` and mounted into pods at runtime (so you can change nginx config without rebuilding the image)

#### `frontend/Dockerfile`
Two-stage build: Stage 1 uses `node:20-alpine` to install dependencies and process assets. Stage 2 copies results into `nginx:alpine`. Final image is ~25MB.

#### `backend/src/server.js`
Express API with:
- `GET /api/ping` — liveness check (never touches DB)
- `GET /api/health` — readiness check (tests DB connection)
- `GET /api/items` — fetches data from MySQL
- `POST /api/items` — inserts data into MySQL
- Graceful shutdown on SIGTERM (required for zero-downtime rolling updates)
- All secrets read from environment variables injected by Vault Agent

#### `backend/Dockerfile`
Two-stage build: Stage 1 installs all dependencies. Stage 2 copies only production dependencies and runs as a non-root user (`node`, UID 1000). This prevents privilege escalation inside the container.

#### `database/init.sql`
Creates the `appdb` database, `items` table, and inserts sample seed rows. This SQL is run once when MySQL starts for the first time.

#### `docker-compose.yml`
Local development stack. Starts all four services (frontend, backend, MySQL, Vault in dev mode) on a custom bridge network. Vault runs in dev mode (auto-unsealed, no persistence) for convenience. **Not used in production.**

---

### Kubernetes Manifests (`k8s/`)

#### `k8s/namespace.yaml`
Creates the `production` namespace with the label `vault-injection: enabled`. This label is required — the Vault Agent Injector webhook filters on it to decide which namespaces to inject into.

#### `k8s/configmap.yaml`
Stores non-sensitive application configuration as key-value pairs:
- `DB_HOST`, `DB_PORT`, `DB_NAME` — database connection parameters
- `ALLOWED_ORIGINS`, `APP_DOMAIN` — CORS configuration
- `RATE_LIMIT_MAX`, `RATE_LIMIT_WINDOW` — rate limiting
- **Never store passwords or keys here.** Those come from Vault.

#### `k8s/nginx-configmap.yaml`
The complete Nginx configuration stored as a ConfigMap and mounted into the frontend pods. This allows you to update Nginx routing rules without rebuilding the Docker image.

#### `k8s/backend-deployment.yaml`
- 3 replicas for high availability
- `maxUnavailable: 0` for zero-downtime rolling updates
- Vault Agent Injector annotations to inject DB credentials
- Downward API to expose pod name/namespace as environment variables
- Liveness probe on `/api/ping` (never touches DB)
- Readiness probe on `/api/health` (validates DB connectivity before receiving traffic)

#### `k8s/frontend-deployment.yaml`
- 2 replicas
- Nginx ConfigMap mounted at `/etc/nginx/conf.d/default.conf`
- Liveness and readiness probes on `/`
- Resource requests and limits set

#### `k8s/ingress.yaml`
NGINX Ingress resource that:
- Routes `/api/*` to `backend-service:3000`
- Routes `/` to `frontend-service:80`
- Enforces HTTPS redirect
- References the TLS secret `app-tls-cert` (created automatically by cert-manager)
- Annotated with `cert-manager.io/cluster-issuer: letsencrypt-prod` to trigger certificate issuance

#### `k8s/hpa.yaml`
Horizontal Pod Autoscaler for both frontend and backend:
- Backend: min 3, max 10 replicas — scales on CPU > 70%
- Frontend: min 2, max 6 replicas — scales on CPU > 70%
- Asymmetric stabilization windows (scale-up fast, scale-down slow)
- PodDisruptionBudgets ensuring at least 1 pod is always available during node drains

---

### Vault Files (`vault/`)

#### `vault/vault-install.yaml` and `helm/vault-values.yaml`
Helm chart values for installing Vault. Key settings:
- Standalone mode (single pod) — suitable for learning/dev
- Vault Agent Injector enabled with 2 replicas for HA
- `standard-rwo` storage class (GKE-compatible)
- UI enabled (ClusterIP, access via port-forward)

#### `vault/vault-auth.yaml`
Configures the Kubernetes authentication method so pods can authenticate to Vault using their ServiceAccount tokens. Also creates the `vault-sa` ServiceAccount used by the application pods.

#### `vault/vault-policy.hcl`
Least-privilege ACL policy. Grants read-only access to specific secret paths:
- `secret/data/app` — backend application secrets (DB password, JWT secret)
- `secret/data/mysql` — MySQL root password

#### `vault/secrets-config.yaml`
Documentation-as-code file showing what secret paths are used and what keys they contain. Does not contain actual values.

---

### cert-manager Files

#### `cert-manager/cluster-issuer.yaml`
Defines two `ClusterIssuer` resources:
- `letsencrypt-prod` — production Let's Encrypt (trusted certificates, rate-limited)
- `letsencrypt-staging` — staging Let's Encrypt (untrusted but unlimited — use for testing)

When the Ingress is applied, cert-manager reads its annotation, triggers the HTTP-01 ACME challenge, and stores the signed certificate in the Secret `app-tls-cert`.

---

### Scripts (`scripts/`)

| Script | Purpose |
|---|---|
| `cluster-setup.sh` | Create GKE cluster with quota-safe disk settings |
| `artifact-registry-setup.sh` | Create GAR Docker repository |
| `docker-auth.sh` | Authenticate Docker CLI with GAR |
| `build-images.sh` | Build frontend + backend images with BuildKit |
| `push-images.sh` | Tag and push images to GAR |
| `deploy-vault.sh` | Install Vault via Helm, initialize, unseal, save keys |
| `vault-secrets.sh` | Configure Vault Kubernetes auth, write app secrets |
| `deploy-database.sh` | Deploy MySQL StatefulSet with correct Vault annotations |
| `deploy-k8s.sh` | Deploy all application manifests, verify Vault connectivity |
| `dns-setup.sh` | Retrieve LB IP, wait for DNS propagation, apply ingress |
| `dns-validate.sh` | End-to-end DNS, HTTPS, and TLS validation |
| `verify-deployment.sh` | Full health check: Vault, MySQL, backend, frontend, HPA |
| `rolling-update.sh` | Zero-downtime image update with auto-rollback on failure |
| `scale-app.sh` | Manually scale replicas (before HPA kicks in) |
| `cleanup.sh` | Remove resources safely with confirmation prompt |

---

## Prerequisites

Ensure the following tools are installed and configured on your local machine before starting.

### Required Tools

```bash
# 1. Google Cloud SDK (gcloud)
# Install: https://cloud.google.com/sdk/docs/install
gcloud version          # Minimum: 450+

# 2. kubectl
gcloud components install kubectl
kubectl version --client

# 3. Docker (with BuildKit support)
docker --version        # Minimum: 23+

# 4. Helm
# Install: https://helm.sh/docs/intro/install/
helm version            # Minimum: 3.12+

# 5. HashiCorp Vault CLI
# Install: https://developer.hashicorp.com/vault/install
vault version

# 6. dig (for DNS validation)
# Linux:  sudo apt-get install dnsutils
# macOS:  brew install bind

# 7. curl, jq
sudo apt-get install curl jq   # or brew install curl jq
```

### GCP Setup

```bash
# Authenticate with GCP
gcloud auth login
gcloud auth application-default login

# Set your project
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  dns.googleapis.com
```

### Domain Setup

You need a domain with an A record pointing to the GKE Load Balancer IP. This project uses `enterprise-app.duckdns.org` as the example. You can get a free subdomain from [DuckDNS](https://www.duckdns.org) or use any domain you own.

---

## Environment Variables Reference

These environment variables control script behavior. All have sensible defaults — override only what differs in your environment.

| Variable | Default | Description |
|---|---|---|
| `GCP_PROJECT_ID` | `naveen-devops-cicd` | Your GCP project ID |
| `GCP_REGION` | `asia-south1` | GCP region for cluster + registry |
| `GCP_ZONE` | `asia-south1-a` | GCP zone for cluster |
| `GKE_CLUSTER_NAME` | `gke-microservices` | Name of the GKE cluster |
| `GKE_MACHINE_TYPE` | `e2-standard-2` | Node machine type |
| `GKE_NODE_COUNT` | `2` | Initial number of nodes |
| `GKE_DISK_SIZE` | `30` | Node boot disk size in GB |
| `GAR_REPO_NAME` | `prod-repo` | Artifact Registry repository name |
| `APP_VERSION` | `1.0.0` | Application image version tag |
| `K8S_NAMESPACE` | `production` | Kubernetes namespace for the app |
| `VAULT_NAMESPACE` | `vault` | Kubernetes namespace for Vault |
| `VAULT_LOCAL_PORT` | `8200` | Local port for Vault port-forward |

### Exporting Variables (Recommended)

Create a file `env.sh` (add it to `.gitignore`) and source it before running scripts:

```bash
# env.sh — DO NOT COMMIT THIS FILE
export GCP_PROJECT_ID="your-actual-project-id"
export GCP_REGION="asia-south1"
export GCP_ZONE="asia-south1-a"
export GAR_REPO_NAME="prod-repo"
export GKE_CLUSTER_NAME="gke-microservices"
export APP_VERSION="1.0.0"
```

```bash
source env.sh
```

---

## GitHub Secrets Reference

These secrets must be configured in your GitHub repository under **Settings → Secrets and variables → Actions**.

| Secret Name | Description | Example |
|---|---|---|
| `GCP_PROJECT_ID` | Your GCP project ID | `my-project-123` |
| `GCP_SA_KEY` | Base64-encoded service account JSON key | `eyJhbGc...` |
| `GCP_REGION` | GCP region | `asia-south1` |
| `GKE_CLUSTER` | GKE cluster name | `gke-microservices` |
| `GKE_ZONE` | GKE zone | `asia-south1-a` |
| `GAR_REPO_NAME` | Artifact Registry repo name | `prod-repo` |

### Creating the Service Account Key

```bash
# Create a service account for CI/CD
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions CI/CD"

# Grant required roles
gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
  --member="serviceAccount:github-actions-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
  --member="serviceAccount:github-actions-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/container.developer"

# Create and download the JSON key
gcloud iam service-accounts keys create sa-key.json \
  --iam-account="github-actions-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

# Encode it to base64 for the GitHub secret
base64 -w 0 sa-key.json
# Paste the output as the GCP_SA_KEY secret value
```

---

## Complete Deployment Guide (Step-by-Step)

Follow the phases in order. Each phase depends on the previous one.

---

### Phase 0 — Local Development (Docker Compose)

Use Docker Compose to test the full stack locally before deploying to GKE. This is optional but strongly recommended.

**Step 1: Start all services**

```bash
# From the project root directory
docker-compose up -d
```

This starts:
- `frontend` — http://localhost:80
- `backend`  — http://localhost:3000
- `mysql`    — localhost:3306
- `vault`    — http://localhost:8200 (dev mode, token = `root`)

**Step 2: Verify services are healthy**

```bash
# Check all containers are running
docker-compose ps

# Test backend health endpoint
curl http://localhost:3000/api/health

# Test via frontend proxy
curl http://localhost:80/api/ping

# Tail backend logs
docker-compose logs -f backend
```

**Step 3: Stop local environment**

```bash
# Stop without deleting volumes (data preserved)
docker-compose down

# Stop AND delete volumes (fresh start next time)
docker-compose down -v
```

---

### Phase 1 — GKE Cluster Setup

**Step 1: Check your GCP quota (prevents errors)**

```bash
# Check SSD and disk quota in your region before creating the cluster
gcloud compute regions describe asia-south1 \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -E "DISK|SSD"
```

> **Note:** The script uses `pd-balanced` disks (not `pd-ssd`) and 2 nodes × 30 GB to stay within GCP free-tier SSD quotas. If you see `Quota exceeded` errors, reduce `GKE_DISK_SIZE` further.

**Step 2: Create the GKE cluster**

```bash
bash scripts/cluster-setup.sh
```

This script:
1. Runs a pre-flight quota check
2. Creates a 2-node `e2-standard-2` cluster in `asia-south1-a`
3. Enables cluster autoscaler (min 2, max 4 nodes)
4. Configures `kubectl` credentials automatically

**Step 3: Verify cluster is running**

```bash
kubectl get nodes
# Expected: 2 nodes in Ready state
```

**Optional overrides at runtime:**

```bash
GKE_NODE_COUNT=3 GKE_DISK_SIZE=20 bash scripts/cluster-setup.sh
```

---

### Phase 2 — Artifact Registry & Docker Images

**Step 1: Create the Artifact Registry repository**

```bash
bash scripts/artifact-registry-setup.sh
```

This creates the Docker repository at:
`asia-south1-docker.pkg.dev/YOUR_PROJECT_ID/prod-repo`

Also configures a cleanup policy: keeps the last 10 image versions and deletes anything older than 30 days.

**Step 2: Authenticate Docker with the registry**

```bash
bash scripts/docker-auth.sh
```

Uses `gcloud auth configure-docker` for local development, or a base64-encoded service account key (`GCP_SA_KEY`) for CI environments.

**Step 3: Build the Docker images**

```bash
# Build version 1.0.0 (default)
bash scripts/build-images.sh

# Build a specific version
bash scripts/build-images.sh 1.2.0
```

Uses BuildKit (`DOCKER_BUILDKIT=1`) for faster parallel builds. Creates two images locally: `frontend:1.0.0` and `backend:1.0.0`.

**Step 4: Push images to Artifact Registry**

```bash
# Push version 1.0.0 (default)
bash scripts/push-images.sh

# Push a specific version
bash scripts/push-images.sh 1.2.0
```

Tags each image with both `VERSION` and `latest`, then pushes both tags.

---

### Phase 3 — HashiCorp Vault

Vault manages all secrets. It must be deployed and configured before the application.

**Step 1: Install Vault via Helm**

```bash
bash scripts/deploy-vault.sh
```

This script:
1. Adds the HashiCorp Helm repo
2. Installs Vault using `helm/vault-values.yaml` into the `vault` namespace
3. Waits for the Vault pod to be running
4. Initializes Vault (generates 5 unseal keys + root token)
5. Unseals Vault using 3 of the 5 keys
6. Saves keys + root token to `vault-init-keys.json` and `/tmp/.vault-env`

> **Important:** The file `vault-init-keys.json` contains your unseal keys and root token. Keep it safe. Do NOT commit it to git (it is in `.gitignore`).

**Step 2: Configure Vault Kubernetes auth and write application secrets**

```bash
bash scripts/vault-secrets.sh
```

This script:
1. Starts a port-forward to Vault (`localhost:8200`)
2. Enables the Kubernetes authentication method
3. Configures it with the cluster's CA certificate (read from inside the Vault pod)
4. Creates the ACL policies from `vault/vault-policy.hcl`
5. Creates Vault roles binding ServiceAccounts to policies
6. Writes secrets at `secret/app` and `secret/mysql`

> **Note:** This script is fully automated. You do not need to run any `vault` CLI commands manually.

**Step 3: Verify Vault is working**

```bash
# Check Vault pod status
kubectl get pods -n vault

# Open Vault UI (in a separate terminal)
kubectl port-forward -n vault svc/vault 8200:8200 &
# Then open http://localhost:8200 in your browser
# Use the root token from vault-init-keys.json to log in
```

---

### Phase 4 — Database Deployment

**Step 1: Deploy MySQL**

```bash
bash scripts/deploy-database.sh
```

This script deploys:
- PersistentVolumeClaim (`mysql-pvc.yaml`) — 20Gi on `standard-rwo`
- ConfigMap with MySQL config + init SQL
- MySQL StatefulSet with the correct `vault.hashicorp.com/service` annotation pointing to `http://vault.vault.svc.cluster.local:8200`

> **Why a dedicated script?** The Vault Agent init container inside the MySQL pod must reach Vault via in-cluster DNS (`vault.vault.svc.cluster.local`), not via localhost. This script generates the manifest with the correct annotation instead of relying on the static `database/mysql-deployment.yaml` file.

**Step 2: Verify MySQL is running**

```bash
kubectl get pods -n production
# Expected: mysql-0 is Running (may take 1-2 minutes on first start)

kubectl logs mysql-0 -n production | tail -20
# Expected: "ready for connections" in the log output
```

---

### Phase 5 — Application Deployment

**Step 1: Deploy frontend, backend, and ingress**

```bash
# Deploy version 1.0.0 (default)
bash scripts/deploy-k8s.sh

# Deploy a specific version
bash scripts/deploy-k8s.sh 1.2.0
```

This script:
1. Verifies Vault is reachable and unsealed
2. Auto-loads Vault token from `/tmp/.vault-env` if not exported
3. Verifies secrets exist in Vault (runs `vault-secrets.sh` if not)
4. Installs cert-manager if not already installed
5. Applies `cert-manager/cluster-issuer.yaml`
6. Applies all manifests in `k8s/` (namespace, configmap, deployments, services, ingress, HPA)
7. Updates image tags to the specified version
8. Waits for rollouts to complete with diagnostics on failure

**Step 2: Verify pods are running**

```bash
kubectl get pods -n production
# Expected output:
#   frontend-xxxx   2/2   Running   (2 replicas)
#   backend-xxxx    3/3   Running   (3 replicas, including Vault sidecar)
#   mysql-0         2/2   Running   (1 pod, including Vault sidecar)
```

**Step 3: Check services and ingress**

```bash
kubectl get svc -n production
kubectl get ingress -n production

# Get the external IP of the NGINX Ingress Controller
kubectl get svc -n ingress-nginx
# Copy the EXTERNAL-IP — you will need it for DNS setup
```

---

### Phase 6 — DNS & TLS Setup

**Step 1: Configure your DNS A record**

Go to your DNS registrar (or DuckDNS dashboard) and create an A record:

```
Type:  A
Name:  enterprise-app    (or @  if using the root domain)
Value: <EXTERNAL-IP from Step 3 above>
TTL:   300
```

**Step 2: Wait for DNS propagation and apply ingress**

```bash
bash scripts/dns-setup.sh
```

This script:
1. Retrieves the Load Balancer external IP from the cluster
2. Prints the exact DNS record you need to add
3. Polls Google DNS (8.8.8.8 and 8.8.4.4) every 30 seconds until propagation is confirmed (up to 30 minutes)
4. Once propagated, updates `k8s/ingress.yaml` and `k8s/configmap.yaml` with the correct domain
5. Applies the updated manifests

> **Note:** DNS propagation typically takes 2–10 minutes for DuckDNS. It can take up to 48 hours for traditional registrars (though usually much faster).

**Step 3: Monitor TLS certificate issuance**

cert-manager automatically requests a certificate from Let's Encrypt once DNS is propagated.

```bash
# Watch cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager -f

# Check certificate status
kubectl get certificate -n production
# Expected: READY = True (takes 1-3 minutes after DNS is ready)

# Check the Certificate resource details if it's stuck
kubectl describe certificate app-tls-cert -n production
```

**Step 4: Test HTTPS access**

```bash
# Should return 200 and redirect to HTTPS
curl -L https://enterprise-app.duckdns.org/api/ping

# Open in browser
echo "https://enterprise-app.duckdns.org"
```

---

### Phase 7 — Verify Everything

**Full deployment verification:**

```bash
bash scripts/verify-deployment.sh
```

This script runs 10 checks:
1. Vault pod status and seal state
2. MySQL pod and DB connectivity
3. Backend deployment and replica count
4. Frontend deployment and replica count
5. HPA status for both frontend and backend
6. Ingress resource status
7. DNS resolution via Google DNS (8.8.8.8 and 8.8.4.4)
8. HTTPS endpoint responses (`/api/health`, `/api/ping`)
9. TLS certificate details (issuer, expiry date)
10. HTTP → HTTPS redirect verification

**DNS and HTTPS-specific validation:**

```bash
bash scripts/dns-validate.sh

# Validate a custom domain
bash scripts/dns-validate.sh --domain your-custom-domain.com
```

---

## CI/CD Pipeline

The GitHub Actions pipeline has two workflows that run automatically.

### CI Workflow (`.github/workflows/ci.yml`)

Triggered on:
- Push to `master` or `develop` branch
- Pull request to `master`
- Manual `workflow_dispatch`

**Stages:**

```
Stage 1: Code Validation
  ├── ESLint on backend code
  └── Jest unit tests (backend/src/server.test.js)

Stage 2: Docker Build
  ├── Build frontend image
  └── Build backend image

Stage 3: Security Scan (Trivy)
  ├── Scan frontend image for HIGH/CRITICAL CVEs
  └── Scan backend image for HIGH/CRITICAL CVEs

Stage 4: Push to Artifact Registry
  ├── Tag images with git SHA (e.g. sha-abc1234)
  ├── Tag images with semantic version (if provided)
  └── Push to asia-south1-docker.pkg.dev/PROJECT/prod-repo
```

### CD Workflow (`.github/workflows/cd.yml`)

Triggered automatically after CI succeeds on `master`. Can also be triggered manually.

**Flow:**

```
1. Authorize GitHub Actions runner IP in GKE firewall
2. Authenticate to GKE with service account
3. Deploy: kubectl set image for frontend + backend
4. Wait for rollout: kubectl rollout status (5-minute timeout)
5. Health check: curl /api/health on the live domain
6. On success: revoke runner IP from firewall
7. On failure: kubectl rollout undo → restore previous version
```

> **Safety note:** `cancel-in-progress: false` prevents concurrent deploys, which could leave the cluster in a half-deployed state.

---

## Day-2 Operations Scripts

### Rolling Update (Zero-Downtime)

```bash
# Update backend only
bash scripts/rolling-update.sh backend 1.2.0

# Update frontend only
bash scripts/rolling-update.sh frontend 1.2.0

# Update both at once
bash scripts/rolling-update.sh all 1.2.0
```

The script:
1. Annotates the deployment with the new version (visible in `kubectl rollout history`)
2. Updates the container image
3. Waits for rollout to complete (5-minute timeout)
4. Automatically runs `kubectl rollout undo` if rollout fails

### Manual Scaling

```bash
# Scale backend to 5 replicas
bash scripts/scale-app.sh backend 5

# Scale frontend to 3 replicas
bash scripts/scale-app.sh frontend 3

# Scale both to 5
bash scripts/scale-app.sh all 5
```

> **Note:** The HPA will eventually override manual scaling if CPU usage changes. Use this for emergency scale-up during traffic spikes while waiting for HPA to react.

### Manual Rollback

```bash
# Roll back to the previous version
kubectl rollout undo deployment/backend -n production
kubectl rollout undo deployment/frontend -n production

# Roll back to a specific revision
kubectl rollout history deployment/backend -n production
kubectl rollout undo deployment/backend --to-revision=2 -n production
```

### Checking Logs

```bash
# Backend logs (all replicas)
kubectl logs -l app=backend -n production --tail=100 -f

# Frontend logs
kubectl logs -l app=frontend -n production --tail=100

# MySQL logs
kubectl logs mysql-0 -n production --tail=100

# Vault logs
kubectl logs -n vault -l app.kubernetes.io/name=vault --tail=100
```

### Accessing the Vault UI

```bash
# Start port-forward
kubectl port-forward -n vault svc/vault 8200:8200 &

# Get the root token
cat vault-init-keys.json | jq -r '.root_token'
# Or: cat /tmp/.vault-env | grep VAULT_TOKEN

# Open http://localhost:8200 in your browser
```

---

## Cleanup

### Remove application resources only (keep PVC data)

```bash
bash scripts/cleanup.sh
# You will be prompted to type 'yes' to confirm
```

### Remove everything including MySQL data (irreversible)

```bash
bash scripts/cleanup.sh --full
# You will be prompted to type 'yes' to confirm
```

### Remove without confirmation prompt (for CI/CD)

```bash
bash scripts/cleanup.sh --force
bash scripts/cleanup.sh --full --force
```

### Delete the entire GKE cluster

```bash
gcloud container clusters delete gke-microservices \
  --zone=asia-south1-a \
  --quiet
```

---

## Troubleshooting

### Pod stuck in `Pending`

```bash
# Check why the pod cannot be scheduled
kubectl describe pod <pod-name> -n production

# Common causes:
#   - Insufficient CPU/memory: check node capacity
#     kubectl describe nodes | grep -A5 "Allocated resources"
#   - PVC not bound: check storage class
#     kubectl get pvc -n production
```

### Pod stuck in `Init:0/1` (Vault Agent init container)

```bash
# Check init container logs
kubectl logs <pod-name> -n production -c vault-agent-init

# Root cause: Vault Agent cannot reach Vault
# Fix: Ensure the pod annotation vault.hashicorp.com/service is set to:
#      http://vault.vault.svc.cluster.local:8200
# Run deploy-database.sh or deploy-k8s.sh which sets this correctly
```

### `CrashLoopBackOff` on backend

```bash
# Check backend container logs
kubectl logs <backend-pod-name> -n production

# Common causes:
#   - DB_PASSWORD not injected (Vault issue)
#   - MySQL not ready yet (wait and let it retry)
#   - Missing environment variable

# Check what environment variables the pod actually has
kubectl exec <backend-pod-name> -n production -- env | grep DB_
```

### cert-manager certificate not issuing

```bash
# Check the Certificate resource
kubectl describe certificate app-tls-cert -n production

# Check CertificateRequest
kubectl get certificaterequest -n production

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager -f

# Common causes:
#   - DNS not propagated yet (run dns-validate.sh to check)
#   - Let's Encrypt rate limit hit (use letsencrypt-staging issuer for testing)
```

### GKE cluster creation fails with `Quota exceeded`

```bash
# Check your current quota
gcloud compute regions describe asia-south1 \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -E "DISK|SSD|CPU"

# Solutions:
#   - Request quota increase in GCP console
#   - Reduce GKE_DISK_SIZE (e.g. GKE_DISK_SIZE=20 bash scripts/cluster-setup.sh)
#   - Delete unused disks: gcloud compute disks list --filter="zone:asia-south1-a"
```

### Vault sealed after pod restart

```bash
# Vault loses its in-memory master key on restart and needs re-unsealing
# Use the keys from vault-init-keys.json

export VAULT_ADDR=http://127.0.0.1:8200
kubectl port-forward -n vault svc/vault 8200:8200 &

# Unseal with 3 of the 5 keys
vault operator unseal $(cat vault-init-keys.json | jq -r '.unseal_keys_b64[0]')
vault operator unseal $(cat vault-init-keys.json | jq -r '.unseal_keys_b64[1]')
vault operator unseal $(cat vault-init-keys.json | jq -r '.unseal_keys_b64[2]')
```

---

*README generated for Task8-v6 — Enterprise GKE Deployment with Vault, cert-manager, and GitHub Actions CI/CD.*