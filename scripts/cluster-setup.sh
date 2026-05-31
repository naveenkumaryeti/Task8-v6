#!/usr/bin/env bash
# ============================================================
# cluster-setup.sh  —  FIXED for SSD Quota Exceeded error
#
# ROOT CAUSE OF ERROR:
#   "Quota exceeded: Your Ssd Total Gb usage has exceeded the limit"
#
#   The original script used:
#     --disk-type="pd-ssd"    ← counted against SSD_TOTAL_GB quota
#     --disk-size="50"        ← 3 nodes × 50 GB = 150 GB SSD consumed
#     --num-nodes=3           ← further multiplied quota usage
#
#   GCP free-tier / new projects have a very low SSD quota in asia-south1
#   (typically 250 GB total, often already partially used by PVCs, boot disks
#   from previous clusters, or Artifact Registry).
#
# FIXES APPLIED:
#   FIX 1 — disk-type: pd-ssd  →  pd-balanced
#            pd-balanced draws from DISK_TOTAL_GB quota (not SSD_TOTAL_GB).
#            Performance is nearly identical to pd-ssd for node OS disks
#            (OS reads are heavily cached; the node root disk is NOT your
#            application data disk — MySQL PVC uses standard-rwo separately).
#
#   FIX 2 — disk-size: 50 GB  →  30 GB
#            GKE minimum is 10 GB. 30 GB is sufficient for the node OS,
#            container image layers, and kubelet ephemeral storage.
#            30 GB × 2 nodes = 60 GB balanced disk (well within quota).
#
#   FIX 3 — num-nodes: 3  →  2  (and min-nodes: 2 → 2, max-nodes: 6 → 4)
#            The error screenshot shows "2 (estimated)" nodes with Error status.
#            Reducing from 3 to 2 initial nodes reduces both quota consumption
#            and monthly GCE cost significantly for a dev/learning cluster.
#            Two e2-standard-2 nodes still comfortably run:
#              frontend (2 pods) + backend (3 pods) + mysql (1 pod) + vault
#
#   FIX 4 — Added pre-flight quota check that prints current SSD + balanced
#            disk usage BEFORE attempting cluster creation so you can see
#            exactly how much quota remains.
#
#   FIX 5 — Added --no-enable-shielded-nodes fallback note.
#            Shielded nodes are fine; kept them. But noted in comments that
#            they can be disabled to unblock creation on very restricted projects.
#
# DISK TYPE COMPARISON:
#   pd-ssd      → NVMe SSD, fast IOPS, counts against SSD_TOTAL_GB quota   ← ORIGINAL (caused error)
#   pd-balanced → Balanced persistent disk, good IOPS, counts against DISK_TOTAL_GB quota  ← FIXED
#   pd-standard → HDD, slowest, counts against DISK_TOTAL_GB quota (also fine if needed)
#
# QUOTA REFERENCE (asia-south1 typical limits for new GCP projects):
#   SSD_TOTAL_GB:      250  GB  ← easy to exhaust; 3 nodes × 50 GB = 150 GB
#   DISK_TOTAL_GB:     2048 GB  ← much larger; 2 nodes × 30 GB = 60 GB
#
# TO CHECK YOUR CURRENT QUOTA:
#   gcloud compute regions describe asia-south1 \
#     --format="table(quotas.metric,quotas.limit,quotas.usage)" \
#     | grep -E "DISK|SSD"
#
# Usage:
#   bash scripts/cluster-setup.sh
#
# Override any default at runtime:
#   GKE_DISK_SIZE=20 GKE_NODE_COUNT=2 bash scripts/cluster-setup.sh
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ── Configuration ──────────────────────────────────────────────────────────────
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
CLUSTER_NAME="${GKE_CLUSTER_NAME:-gke-microservices}"
REGION="${GCP_REGION:-asia-south1}"
ZONE="${GCP_ZONE:-asia-south1-a}"

# FIX 3: Reduced from 3 → 2 initial nodes to minimise quota consumption.
# Two e2-standard-2 nodes = 4 vCPU + 8 GB RAM per node = 8 vCPU + 16 GB total.
# That comfortably fits: frontend(2) + backend(3) + mysql(1) + vault(1) pods.
NODE_COUNT="${GKE_NODE_COUNT:-2}"

MACHINE_TYPE="${GKE_MACHINE_TYPE:-e2-standard-2}"

# FIX 2: Reduced from 50 GB → 30 GB per node.
# Node OS disk only needs ~10–20 GB; container image layers add ~5–10 GB.
# 30 GB provides comfortable headroom without burning quota.
DISK_SIZE="${GKE_DISK_SIZE:-30}"

# FIX 1: Changed from pd-ssd → pd-balanced.
# pd-balanced draws from DISK_TOTAL_GB quota (2048 GB limit) instead of
# SSD_TOTAL_GB quota (250 GB limit) — completely avoids the quota error.
DISK_TYPE="${GKE_DISK_TYPE:-pd-balanced}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
info() { echo -e "${CYAN}[$(date +'%H:%M:%S')] ➜ $*${NC}"; }

# ── Helper: detect current public IPv4 ────────────────────────────────────────
# Uses -4 to force IPv4 — GKE master-authorized-networks rejects IPv6 CIDRs.
detect_ipv4() {
  local ip
  ip=$(
    curl -sf -4 --max-time 5 https://checkip.amazonaws.com ||
    curl -sf -4 --max-time 5 https://ifconfig.me          ||
    curl -sf -4 --max-time 5 https://api4.my-ip.io/ip     ||
    echo ""
  )
  ip="${ip//[$'\t\r\n ']}"
  echo "$ip"
}

# ── Validate prerequisites ─────────────────────────────────────────────────────
log "Validating prerequisites..."
command -v gcloud >/dev/null 2>&1 || fail "gcloud CLI not found."
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found. Run: gcloud components install kubectl"

gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@" || \
  fail "Not authenticated. Run: gcloud auth login"

# ── Set active project ─────────────────────────────────────────────────────────
log "Setting project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# ── FIX 4: Pre-flight quota check ─────────────────────────────────────────────
# Show current disk quota consumption BEFORE creating the cluster.
# This lets you see exactly how much headroom you have and diagnose quota errors
# before they happen instead of after a 6-minute failed cluster creation attempt.
log "Checking disk quota in region: $REGION"
echo ""
echo -e "${CYAN}  Current disk quota usage in $REGION:${NC}"
gcloud compute regions describe "$REGION" \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  2>/dev/null | grep -E "METRIC|DISK|SSD" || \
  warn "Could not retrieve quota info — proceeding anyway"

echo ""
# Calculate what this cluster will consume
NODES_TOTAL_DISK_GB=$(( NODE_COUNT * DISK_SIZE ))
info "This cluster will use: ${NODE_COUNT} nodes × ${DISK_SIZE} GB ${DISK_TYPE} = ${NODES_TOTAL_DISK_GB} GB"

if [[ "$DISK_TYPE" == "pd-ssd" ]]; then
  warn "DISK_TYPE is pd-ssd — this consumes SSD_TOTAL_GB quota (low limit)."
  warn "If you see quota errors, set: GKE_DISK_TYPE=pd-balanced bash $0"
else
  log "DISK_TYPE is $DISK_TYPE — uses DISK_TOTAL_GB quota (high limit, avoids SSD quota error) ✓"
fi
echo ""

# ── Enable required GCP APIs ───────────────────────────────────────────────────
log "Enabling required GCP APIs..."
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudkms.googleapis.com \
  secretmanager.googleapis.com \
  --quiet

# ── Auto-detect public IPv4 ────────────────────────────────────────────────────
# Override at runtime:  MY_PUBLIC_IP=1.2.3.4 bash scripts/cluster-setup.sh
if [[ -z "${MY_PUBLIC_IP:-}" ]]; then
  log "Auto-detecting public IP for master authorized networks..."
  MY_PUBLIC_IP=$(detect_ipv4)
fi

if [[ ! "$MY_PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  fail "Could not detect a valid public IPv4 (got: '${MY_PUBLIC_IP:-empty}'). Set manually: MY_PUBLIC_IP=1.2.3.4 bash $0"
fi

log "Public IP: $MY_PUBLIC_IP — will be whitelisted for cluster API access"

# ── Create GKE Cluster ─────────────────────────────────────────────────────────
log "Creating GKE cluster: $CLUSTER_NAME in $ZONE"
log "Machine: $MACHINE_TYPE | Nodes: $NODE_COUNT | Disk: ${DISK_SIZE}GB ${DISK_TYPE}"

if gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
  warn "Cluster '$CLUSTER_NAME' already exists — skipping creation"
else
  gcloud container clusters create "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --num-nodes="$NODE_COUNT" \
    --machine-type="$MACHINE_TYPE" \
    --disk-size="${DISK_SIZE}GB" \
    --disk-type="$DISK_TYPE" \
    \
    `# ── Security hardening ────────────────────────────────────────────────` \
    `# Shielded nodes verify the integrity of the node OS at boot.         ` \
    `# If your project has a very tight quota or org policy blocks shielded,` \
    `# remove the three lines below and add --no-enable-shielded-nodes.    ` \
    --enable-shielded-nodes \
    --shielded-secure-boot \
    --shielded-integrity-monitoring \
    \
    `# ── Workload Identity (required for Vault + cert-manager IAM) ────────` \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    \
    `# ── Auto-repair and auto-upgrade ─────────────────────────────────────` \
    --enable-autorepair \
    --enable-autoupgrade \
    \
    `# ── Networking ───────────────────────────────────────────────────────` \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr="172.16.0.0/28" \
    --enable-master-authorized-networks \
    --master-authorized-networks="${MY_PUBLIC_IP}/32" \
    \
    `# ── Autoscaling ──────────────────────────────────────────────────────` \
    `# FIX 3: min-nodes=2 (was 2, kept), max-nodes=4 (was 6, reduced).    ` \
    `# Lower max-nodes cap prevents autoscaler from creating extra SSD disks` \
    `# and running into the same quota ceiling during scale-out events.    ` \
    --enable-autoscaling \
    --min-nodes=2 \
    --max-nodes=4 \
    \
    `# ── Observability ────────────────────────────────────────────────────` \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM \
    \
    --labels="environment=production,team=devops,managed-by=gcloud" \
    --quiet

  log "Cluster created successfully! ✓"

  # ── Re-check IP after provisioning ────────────────────────────────────────
  # Cluster creation takes ~6 minutes. Dynamic ISP IPs (common in Hyderabad)
  # can rotate in that window. Re-detect and update master authorized networks.
  log "Re-checking public IP after cluster provisioning..."
  POST_CREATE_IP=$(detect_ipv4)

  if [[ "$POST_CREATE_IP" != "$MY_PUBLIC_IP" ]]; then
    warn "IP changed during provisioning ($MY_PUBLIC_IP → $POST_CREATE_IP). Updating master authorized networks..."
    gcloud container clusters update "$CLUSTER_NAME" \
      --zone="$ZONE" \
      --enable-master-authorized-networks \
      --master-authorized-networks="${POST_CREATE_IP}/32" \
      --quiet
    log "Master authorized networks updated to $POST_CREATE_IP"
    MY_PUBLIC_IP="$POST_CREATE_IP"
  else
    log "IP unchanged ($MY_PUBLIC_IP) — no update needed"
  fi
fi

# ── Configure kubectl context ──────────────────────────────────────────────────
log "Configuring kubectl context..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE"

log "Verifying cluster connectivity..."
kubectl cluster-info
kubectl get nodes -o wide

log "Creating production namespace..."
kubectl apply -f k8s/namespace.yaml

# ── Post-creation quota snapshot ──────────────────────────────────────────────
log "Post-creation quota snapshot (verify consumption):"
gcloud compute regions describe "$REGION" \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  2>/dev/null | grep -E "METRIC|DISK|SSD" || true

echo ""
log "✅ Cluster setup complete!"
log "Cluster: $CLUSTER_NAME | Zone: $ZONE | Nodes: $NODE_COUNT × $MACHINE_TYPE"
log "Disk: ${DISK_SIZE}GB ${DISK_TYPE} per node (total: ${NODES_TOTAL_DISK_GB}GB)"
log "Next step: bash scripts/artifact-registry-setup.sh"

# ── Quota troubleshooting reference ───────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━ If you still see quota errors ━━━━${NC}"
echo -e "  1. View current quotas in the GCP Console:"
echo -e "     https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"
echo -e ""
echo -e "  2. Check from CLI:"
echo -e "     gcloud compute regions describe $REGION \\"
echo -e "       --format='table(quotas.metric,quotas.limit,quotas.usage)' | grep -E 'DISK|SSD'"
echo -e ""
echo -e "  3. Request a quota increase:"
echo -e "     Go to the quotas page above → filter for 'SSD Total GB' or 'Persistent Disk' → Edit Quotas"
echo -e ""
echo -e "  4. Use even smaller disks (absolute minimum is 10 GB):"
echo -e "     GKE_DISK_SIZE=20 bash scripts/cluster-setup.sh"
echo -e ""
echo -e "  5. Switch to pd-standard (HDD) if pd-balanced also hits quota:"
echo -e "     GKE_DISK_TYPE=pd-standard GKE_DISK_SIZE=20 bash scripts/cluster-setup.sh"
