#!/usr/bin/env bash
# ============================================================
# artifact-registry-setup.sh
#
# Creates a Google Artifact Registry repository for Docker images.
# GAR is the successor to GCR — prefer GAR for new projects.
#
# Usage:
#   bash scripts/artifact-registry-setup.sh
# ============================================================

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
REGION="${GCP_REGION:-asia-south1}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

log "Creating Artifact Registry repository: $REPO_NAME in $REGION"

# Check if repository already exists
if gcloud artifacts repositories describe "$REPO_NAME" \
  --location="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null; then
  warn "Repository '$REPO_NAME' already exists — skipping"
else
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --description="Production Docker images for enterprise app" \
    --project="$PROJECT_ID" \
    --labels="environment=production,team=devops"

  log "Repository created: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
fi

# ── Configure cleanup policy ──────────────────────────────────────────────────
# Keep last 10 versions of each image, delete older ones (cost optimization)
log "Configuring cleanup policy..."
gcloud artifacts repositories set-cleanup-policies "$REPO_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --policy='[
    {
      "name": "keep-last-10",
      "action": {"type": "Keep"},
      "mostRecentVersions": {"keepCount": 10}
    },
    {
      "name": "delete-old",
      "action": {"type": "Delete"},
      "condition": {"olderThan": "30d"}
    }
  ]' 2>/dev/null || warn "Cleanup policy requires gcloud >= 450 — skip if older version"

# ── Grant CI/CD service account access ────────────────────────────────────────
# The GitHub Actions service account needs Artifact Registry Writer role
log "Configuring IAM for CI/CD service account..."
if [ -n "${CICD_SA_EMAIL:-}" ]; then
  gcloud artifacts repositories add-iam-policy-binding "$REPO_NAME" \
    --location="$REGION" \
    --member="serviceAccount:${CICD_SA_EMAIL}" \
    --role="roles/artifactregistry.writer" \
    --project="$PROJECT_ID"
  log "Granted artifactregistry.writer to $CICD_SA_EMAIL"
else
  warn "CICD_SA_EMAIL not set — skip IAM binding (set manually or via CI/CD)"
fi

log "✅ Artifact Registry setup complete!"
log "Registry URL: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
log "Next step: bash scripts/docker-auth.sh"
