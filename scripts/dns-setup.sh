#!/usr/bin/env bash
# ============================================================
# scripts/dns-setup.sh  —  NEW SCRIPT
#
# Automates the complete DNS configuration workflow:
#   1. Retrieves the GCP Load Balancer external IP from the cluster
#   2. Prints the exact DNS A Record to add in your registrar
#   3. Polls Google DNS (8.8.8.8 + 8.8.4.4) until propagation is confirmed
#   4. Updates k8s/ingress.yaml and k8s/configmap.yaml with the real domain
#   5. Applies the updated manifests to the cluster
#
# Usage:
#   bash scripts/dns-setup.sh
#
# Prerequisites:
#   - kubectl configured (gcloud container clusters get-credentials ...)
#   - dig installed  (sudo apt-get install dnsutils  OR  brew install bind)
#   - NGINX Ingress Controller running in namespace ingress-nginx
#   - Domain enterprise-app.gt.tc managed via your DNS registrar
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ── Configuration ──────────────────────────────────────────────────────────────
DOMAIN="enterprise-app.gt.tc"
NAMESPACE="${K8S_NAMESPACE:-production}"
DNS_PRIMARY="8.8.8.8"
DNS_SECONDARY="8.8.4.4"
MAX_WAIT_SECONDS=1800      # 30 minutes maximum wait for DNS propagation
POLL_INTERVAL=30           # Check every 30 seconds

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}${BOLD}━━━━ $* ━━━━${NC}"; }
info()  { echo -e "${CYAN}  ➜  $*${NC}"; }

# ── Prerequisite checks ────────────────────────────────────────────────────────
title "Step 0 — Checking Prerequisites"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found. Install: gcloud components install kubectl"
command -v curl    >/dev/null 2>&1 || fail "curl not found."
if command -v dig >/dev/null 2>&1; then
  DNS_TOOL="dig"
elif command -v nslookup >/dev/null 2>&1; then
  DNS_TOOL="nslookup"
else
  fail "Neither dig nor nslookup found. Install dnsutils/bind-tools, or run from Git Bash with nslookup available."
fi

# Verify cluster connectivity
kubectl cluster-info --request-timeout=10s >/dev/null 2>&1 || \
  fail "Cannot connect to Kubernetes cluster. Run: gcloud container clusters get-credentials <CLUSTER_NAME> --zone=<ZONE>"

log "All prerequisites satisfied"
log "DNS lookup tool: $DNS_TOOL"

dns_lookup() {
  local server="$1"
  local domain="$2"
  if [ "$DNS_TOOL" = "dig" ]; then
    dig @"$server" "$domain" +short 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true
  else
    nslookup "$domain" "$server" 2>/dev/null \
      | awk '/^Address: / { print $2 }' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | tail -1 || true
  fi
}

cert_manager_webhook_ready() {
  kubectl get endpoints cert-manager-webhook -n cert-manager \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

wait_for_cert_manager_webhook() {
  local elapsed=0
  while [ "$elapsed" -lt 180 ]; do
    if cert_manager_webhook_ready; then
      return 0
    fi
    warn "cert-manager webhook has no endpoints yet (${elapsed}s elapsed). Waiting 10s..."
    sleep 10
    elapsed=$((elapsed + 10))
  done
  return 1
}

# ── Step 1: Get Load Balancer IP ───────────────────────────────────────────────
title "Step 1 — Retrieving GCP Load Balancer External IP"

# The NGINX Ingress Controller service gets a GCP External Load Balancer IP.
# This is the IP you will set as the DNS A Record target.
# If you used frontend-service LoadBalancer directly, change the selector below.

log "Waiting for NGINX Ingress Controller LoadBalancer IP to be assigned..."
ELAPSED=0
EXTERNAL_IP=""

while [ -z "$EXTERNAL_IP" ] && [ "$ELAPSED" -lt 300 ]; do
  EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller \
    -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [ -z "$EXTERNAL_IP" ]; then
    warn "External IP not yet assigned (${ELAPSED}s elapsed). Waiting ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  fi
done

if [ -z "$EXTERNAL_IP" ]; then
  # Fallback: try to get IP from the frontend-service LoadBalancer
  warn "ingress-nginx-controller IP not found — trying frontend-service..."
  EXTERNAL_IP=$(kubectl get svc frontend-service \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

[ -z "$EXTERNAL_IP" ] && fail "Could not retrieve External IP. Ensure NGINX Ingress Controller is deployed:\n  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml"

log "External IP: ${BOLD}$EXTERNAL_IP${NC}"

# ── Step 1b: Apply Kubernetes domain resources early ─────────────────────────
#
# Create the Ingress before waiting on public DNS. cert-manager can create the
# Certificate/Challenge resources immediately; they will remain Pending until
# the registrar A record resolves to this load balancer IP.
title "Step 1b — Applying Ingress and TLS Resources"

log "Applying k8s/configmap.yaml (ALLOWED_ORIGINS: https://$DOMAIN)..."
kubectl apply -f k8s/configmap.yaml -n "$NAMESPACE"

CLUSTER_ISSUER_APPLIED=false
if kubectl api-resources 2>/dev/null | grep -q '^clusterissuers[[:space:]]'; then
  if wait_for_cert_manager_webhook; then
    log "Applying cert-manager/cluster-issuer.yaml..."
    if kubectl apply -f cert-manager/cluster-issuer.yaml; then
      CLUSTER_ISSUER_APPLIED=true
    else
      warn "ClusterIssuer apply failed. cert-manager webhook may still be starting."
      warn "Continuing DNS setup; rerun this script after: kubectl get pods -n cert-manager"
    fi
  else
    warn "cert-manager webhook is not ready, so ClusterIssuer will be skipped for now."
    warn "Check: kubectl get pods,endpoints -n cert-manager"
  fi
else
  warn "cert-manager ClusterIssuer CRD not available yet — skipping issuer for now."
  warn "Run deploy-k8s.sh again or apply cert-manager before expecting TLS issuance."
fi

log "Applying k8s/ingress.yaml (host: $DOMAIN)..."
kubectl apply -f k8s/ingress.yaml -n "$NAMESPACE"

# ── Step 2: Print DNS configuration instructions ───────────────────────────────
title "Step 2 — DNS A Record Configuration"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           ACTION REQUIRED: Add This DNS A Record            ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  Domain Registrar / DNS Control Panel for gt.tc              ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║  %-12s  %-22s  %-10s  %-8s  ║${NC}\n" "Type" "Name" "Value" "TTL"
echo -e "${BOLD}║──────────────────────────────────────────────────────────────║${NC}"
printf "${GREEN}║  %-12s  %-22s  %-10s  %-8s  ║${NC}\n" "A" "enterprise-app" "$EXTERNAL_IP" "300"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Full DNS zone file entry:"
echo -e "  ${CYAN}enterprise-app.gt.tc.   300   IN   A   $EXTERNAL_IP${NC}"
echo ""
echo -e "  Optional CAA record (restrict cert issuance to Let's Encrypt only):"
echo -e "  ${CYAN}enterprise-app.gt.tc.   300   IN   CAA   0 issue \"letsencrypt.org\"${NC}"
echo ""
warn "Add the A Record above to your DNS registrar NOW, then press ENTER to continue."
read -r -p "  Press ENTER after adding the DNS record... "

# ── Step 3: Poll DNS propagation ───────────────────────────────────────────────
title "Step 3 — Waiting for DNS Propagation (Polling ${DNS_PRIMARY} and ${DNS_SECONDARY})"

log "Polling Google Public DNS until $DOMAIN resolves to $EXTERNAL_IP"
info "Primary DNS:   $DNS_PRIMARY  (nslookup $DOMAIN $DNS_PRIMARY)"
info "Secondary DNS: $DNS_SECONDARY  (nslookup $DOMAIN $DNS_SECONDARY)"
info "Maximum wait:  ${MAX_WAIT_SECONDS}s  (poll interval: ${POLL_INTERVAL}s)"
echo ""

ELAPSED=0
PRIMARY_OK=false
SECONDARY_OK=false

while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
  # Query both Google DNS servers
  RESOLVED_PRIMARY=$(dns_lookup "$DNS_PRIMARY" "$DOMAIN")
  RESOLVED_SECONDARY=$(dns_lookup "$DNS_SECONDARY" "$DOMAIN")

  echo -e "  [$(date +'%H:%M:%S')] Primary   (${DNS_PRIMARY}): ${RESOLVED_PRIMARY:-<not resolved yet>}"
  echo -e "  [$(date +'%H:%M:%S')] Secondary (${DNS_SECONDARY}): ${RESOLVED_SECONDARY:-<not resolved yet>}"

  [ "$RESOLVED_PRIMARY"   = "$EXTERNAL_IP" ] && PRIMARY_OK=true   || PRIMARY_OK=false
  [ "$RESOLVED_SECONDARY" = "$EXTERNAL_IP" ] && SECONDARY_OK=true || SECONDARY_OK=false

  if $PRIMARY_OK && $SECONDARY_OK; then
    echo ""
    log "DNS propagation confirmed on BOTH Google DNS servers!"
    log "  8.8.8.8  → $RESOLVED_PRIMARY ✓"
    log "  8.8.4.4  → $RESOLVED_SECONDARY ✓"
    break
  fi

  warn "Not yet propagated (${ELAPSED}s elapsed). Retrying in ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if ! $PRIMARY_OK || ! $SECONDARY_OK; then
  warn "DNS propagation check timed out after ${MAX_WAIT_SECONDS}s."
  warn "The record may still be propagating. You can continue manually after verification:"
  info "  nslookup $DOMAIN $DNS_PRIMARY   # should return $EXTERNAL_IP"
  info "  nslookup $DOMAIN $DNS_SECONDARY  # should return $EXTERNAL_IP"
  read -r -p "  Continue anyway? [y/N] " CONTINUE
  [[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "Aborted. Re-run after DNS propagates."
fi

# ── Step 4: Apply updated Ingress and ConfigMap ────────────────────────────────
title "Step 4 — Applying Updated Kubernetes Manifests"

# Apply the enhanced ingress (enterprise-app.gt.tc already hardcoded)
log "Applying k8s/ingress.yaml (host: $DOMAIN)..."
kubectl apply -f k8s/ingress.yaml -n "$NAMESPACE"

# Apply the enhanced configmap (ALLOWED_ORIGINS updated to enterprise-app.gt.tc)
log "Applying k8s/configmap.yaml (ALLOWED_ORIGINS: https://$DOMAIN)..."
kubectl apply -f k8s/configmap.yaml -n "$NAMESPACE"

# Restart backend to pick up the new ALLOWED_ORIGINS and APP_DOMAIN env vars
log "Restarting backend deployment to pick up updated ConfigMap..."
kubectl rollout restart deployment/backend -n "$NAMESPACE"
kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=120s
log "Backend rollout complete"

# ── Step 5: Verify Ingress shows the correct external IP and hostname ──────────
title "Step 5 — Ingress Verification"

kubectl get ingress app-ingress -n "$NAMESPACE" -o wide
echo ""

INGRESS_IP=$(kubectl get ingress app-ingress -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [ "$INGRESS_IP" = "$EXTERNAL_IP" ]; then
  log "Ingress IP matches Load Balancer IP: $INGRESS_IP ✓"
else
  warn "Ingress IP ($INGRESS_IP) differs from Load Balancer IP ($EXTERNAL_IP)"
  warn "This may resolve within a few minutes as GKE updates the Ingress status."
fi

# ── Step 6: Wait for cert-manager TLS certificate issuance ───────────────────
title "Step 6 — TLS Certificate Issuance (cert-manager + Let's Encrypt)"

info "cert-manager will now:"
info "  1. Create a Certificate resource for $DOMAIN"
info "  2. Complete an HTTP-01 ACME challenge (serves token at /.well-known/acme-challenge/)"
info "  3. Store the signed certificate in Secret: app-tls-cert"
info "  4. NGINX Ingress Controller picks it up → HTTPS enabled"
echo ""

CERT_WAIT=0
CERT_READY=false

if ! $CLUSTER_ISSUER_APPLIED; then
  warn "Skipping certificate wait because ClusterIssuer was not applied in this run."
  warn "After cert-manager webhook is ready, rerun: bash scripts/dns-setup.sh"
else
log "Watching cert-manager certificate status (press Ctrl+C to stop watching)..."
log "Expected status: READY=True within ~1–3 minutes"

# Watch with a timeout

while [ "$CERT_WAIT" -lt 300 ]; do
  CERT_STATUS=$(kubectl get certificate app-tls-cert -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

  if [ "$CERT_STATUS" = "True" ]; then
    CERT_READY=true
    break
  fi

  echo -e "  [$(date +'%H:%M:%S')] Certificate Ready: ${CERT_STATUS:-Pending...}"
  sleep 15
  CERT_WAIT=$((CERT_WAIT + 15))
done

if $CERT_READY; then
  log "TLS certificate issued successfully! ✓"
  kubectl describe certificate app-tls-cert -n "$NAMESPACE" | grep -E "Not Before|Not After|Common Name|DNS Names" || true
else
  warn "Certificate not yet Ready after ${CERT_WAIT}s."
  warn "Check status: kubectl describe certificate app-tls-cert -n $NAMESPACE"
  warn "Check challenges: kubectl get challenges -n $NAMESPACE"
  warn "Common cause: DNS not yet propagated to Let's Encrypt's resolvers."
fi
fi

# ── Step 7: Final HTTPS verification ─────────────────────────────────────────
title "Step 7 — Final HTTPS Verification"

if $CERT_READY; then
  log "Testing HTTPS endpoint: https://$DOMAIN"
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "https://$DOMAIN/health" 2>/dev/null || echo "000")

  if [ "$HTTP_STATUS" = "200" ]; then
    log "Application is reachable at https://$DOMAIN (HTTP $HTTP_STATUS) ✓"
  else
    warn "HTTPS health check returned HTTP $HTTP_STATUS (expected 200)"
    warn "Ingress or backend may still be starting. Try manually:"
    info "  curl -v https://$DOMAIN/health"
  fi

  log "Testing HTTP → HTTPS redirect..."
  REDIRECT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "http://$DOMAIN" 2>/dev/null || echo "000")

  if [ "$REDIRECT_STATUS" = "301" ] || [ "$REDIRECT_STATUS" = "308" ]; then
    log "HTTP → HTTPS redirect working (HTTP $REDIRECT_STATUS) ✓"
  else
    warn "HTTP redirect returned HTTP $REDIRECT_STATUS (expected 301 or 308)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
title "DNS Setup Complete — Summary"

echo ""
echo -e "${BOLD}  Domain:          ${GREEN}https://$DOMAIN${NC}"
echo -e "${BOLD}  Load Balancer IP: ${GREEN}$EXTERNAL_IP${NC}"
echo -e "${BOLD}  DNS (8.8.8.8):   ${GREEN}$(dns_lookup "$DNS_PRIMARY" "$DOMAIN" || echo 'pending')${NC}"
echo -e "${BOLD}  DNS (8.8.4.4):   ${GREEN}$(dns_lookup "$DNS_SECONDARY" "$DOMAIN" || echo 'pending')${NC}"
echo -e "${BOLD}  TLS Certificate: ${GREEN}$( $CERT_READY && echo "Issued ✓" || echo "Pending — check: kubectl get certificate -n $NAMESPACE")${NC}"
echo ""
echo -e "${BOLD}  Validation commands:${NC}"
echo -e "  ${CYAN}nslookup $DOMAIN $DNS_PRIMARY${NC}"
echo -e "  ${CYAN}nslookup $DOMAIN $DNS_SECONDARY${NC}"
echo -e "  ${CYAN}nslookup $DOMAIN $DNS_PRIMARY${NC}"
echo -e "  ${CYAN}curl -v https://$DOMAIN/health${NC}"
echo -e "  ${CYAN}kubectl get certificate -n $NAMESPACE${NC}"
echo ""
log "✅ DNS setup and domain mapping complete!"
