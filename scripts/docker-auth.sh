#!/usr/bin/env bash
# ============================================================
# docker-auth.sh
#
# Authenticates Docker with Google Artifact Registry.
#
# Two authentication methods:
#   1. gcloud auth (local development / CI with gcloud installed)
#   2. Service account JSON key (CI without gcloud — GitHub Actions)
#
# Usage:
#   bash scripts/docker-auth.sh
# ============================================================

set -euo pipefail

REGION="${GCP_REGION:-asia-south1}"
REGISTRY="${REGION}-docker.pkg.dev"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

# ── Method 1: gcloud auth (preferred for local dev) ───────────────────────────
if command -v gcloud >/dev/null 2>&1; then
  log "Authenticating Docker with gcloud credential helper..."
  gcloud auth configure-docker "$REGISTRY" --quiet
  log "Docker configured to use gcloud for $REGISTRY"

# ── Method 2: Service account JSON (CI environments) ─────────────────────────
elif [ -n "${GCP_SA_KEY:-}" ]; then
  warn "gcloud not found — using service account JSON key (CI mode)"

  # Decode base64-encoded SA key from GitHub Actions secret
  # GitHub Actions secret: GCP_SA_KEY = base64(service-account.json)
  echo "$GCP_SA_KEY" | base64 -d > /tmp/sa-key.json

  # Authenticate with the key
  docker login \
    --username _json_key \
    --password-file /tmp/sa-key.json \
    "https://${REGISTRY}"

  # Clean up key file immediately after use
  rm -f /tmp/sa-key.json
  log "Docker authenticated with service account key"

else
  echo -e "${RED}Error: Neither gcloud CLI nor GCP_SA_KEY env var found${NC}"
  echo "For local use: Install gcloud and run 'gcloud auth login'"
  echo "For CI use: Set GCP_SA_KEY secret (base64-encoded SA JSON key)"
  exit 1
fi

# ── Verify authentication ─────────────────────────────────────────────────────
log "Verifying Docker authentication..."
docker system info | grep -E "Username|Registry" 2>/dev/null || true

log "✅ Docker authentication complete!"
log "Registry: $REGISTRY"
