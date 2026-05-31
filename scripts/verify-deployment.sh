#!/usr/bin/env bash
# ============================================================
# scripts/verify-deployment.sh  —  ENHANCED
#
# CHANGES FROM ORIGINAL:
#   ✅  Added Section 7: Domain Resolution Check (Google DNS 8.8.8.8 / 8.8.4.4)
#   ✅  Added Section 8: HTTPS Endpoint Verification
#   ✅  Added Section 9: TLS Certificate Inspection
#   ✅  Added Section 10: HTTP → HTTPS Redirect Test
#   ✅  Updated Summary to include domain + TLS status
#
# All original checks (Vault, MySQL, Backend, Frontend, Ingress, HPA) preserved unchanged.
#
# Usage:
#   bash scripts/verify-deployment.sh
# ============================================================

set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-production}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
DOMAIN="enterprise-app.gt.tc"
DNS_PRIMARY="8.8.8.8"
DNS_SECONDARY="8.8.4.4"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}━━━━ $* ━━━━${NC}"; }

# ── Vault ─────────────────────────────────────────────────────────────────────
title "Vault Health"

VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$VAULT_POD" ]; then
  warn "No Vault pod found in namespace '$VAULT_NAMESPACE'"
else
  VAULT_PHASE=$(kubectl get pod "$VAULT_POD" -n "$VAULT_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  log "Vault pod: $VAULT_POD  phase=$VAULT_PHASE"

  SEALED=$(kubectl exec "$VAULT_POD" -n "$VAULT_NAMESPACE" -- \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sealed'])" \
    2>/dev/null || echo "unknown")
  [ "$SEALED" = "False" ] && log "Vault is unsealed ✓" || warn "Vault sealed=$SEALED"
fi

kubectl get pods -n "$VAULT_NAMESPACE" -o wide

# ── Namespace ─────────────────────────────────────────────────────────────────
title "Production Namespace — All Pods"
kubectl get pods -n "$NAMESPACE" -o wide

# ── MySQL ─────────────────────────────────────────────────────────────────────
title "MySQL StatefulSet"
kubectl rollout status statefulset/mysql -n "$NAMESPACE" --timeout=60s || \
  warn "MySQL StatefulSet not fully ready"
kubectl get pvc -n "$NAMESPACE"

# ── Backend ───────────────────────────────────────────────────────────────────
title "Backend Deployment"
kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=60s || \
  warn "Backend deployment not fully ready"

BACKEND_READY=$(kubectl get deployment backend -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
log "Backend ready replicas: $BACKEND_READY"

# ── Frontend ──────────────────────────────────────────────────────────────────
title "Frontend Deployment"
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=60s || \
  warn "Frontend deployment not fully ready"

FRONTEND_READY=$(kubectl get deployment frontend -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
log "Frontend ready replicas: $FRONTEND_READY"

# ── Services ──────────────────────────────────────────────────────────────────
title "Services"
kubectl get svc -n "$NAMESPACE"

# ── Ingress / External IP ─────────────────────────────────────────────────────
title "Ingress"
kubectl get ingress -n "$NAMESPACE" 2>/dev/null || warn "No ingress resources found"

EXTERNAL_IP=$(kubectl get ingress -n "$NAMESPACE" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [ -n "$EXTERNAL_IP" ]; then
  log "External IP: $EXTERNAL_IP"
  log "Testing frontend via IP: http://$EXTERNAL_IP"
  curl -sf --max-time 10 "http://$EXTERNAL_IP" -o /dev/null && \
    log "Frontend responded with HTTP 200 ✓" || \
    warn "Frontend did not respond via IP (Ingress may still be provisioning)"
else
  warn "No external IP yet — Ingress controller may still be provisioning"
fi

# ── HPA ───────────────────────────────────────────────────────────────────────
title "Horizontal Pod Autoscalers"
kubectl get hpa -n "$NAMESPACE" 2>/dev/null || warn "No HPA resources found"

# ── NEW Section 7: Domain Resolution Check ────────────────────────────────────
title "Domain Resolution — enterprise-app.gt.tc via Google DNS"

if command -v dig >/dev/null 2>&1; then
  RESOLVED_PRIMARY=$(dig @"$DNS_PRIMARY" "$DOMAIN" +short 2>/dev/null | head -1 || true)
  RESOLVED_SECONDARY=$(dig @"$DNS_SECONDARY" "$DOMAIN" +short 2>/dev/null | head -1 || true)

  log "Querying $DNS_PRIMARY:  ${RESOLVED_PRIMARY:-<not resolved>}"
  log "Querying $DNS_SECONDARY:  ${RESOLVED_SECONDARY:-<not resolved>}"

  if [ -n "$RESOLVED_PRIMARY" ] && [ -n "$RESOLVED_SECONDARY" ]; then
    if [ "$RESOLVED_PRIMARY" = "$RESOLVED_SECONDARY" ]; then
      log "Both DNS servers agree: $RESOLVED_PRIMARY ✓"
      if [ -n "$EXTERNAL_IP" ] && [ "$RESOLVED_PRIMARY" = "$EXTERNAL_IP" ]; then
        log "DNS IP matches Load Balancer IP ($EXTERNAL_IP) ✓"
      elif [ -n "$EXTERNAL_IP" ]; then
        warn "DNS resolves to $RESOLVED_PRIMARY but LB IP is $EXTERNAL_IP — DNS may not be updated"
      fi
    else
      warn "DNS servers disagree: 8.8.8.8=$RESOLVED_PRIMARY  8.8.4.4=$RESOLVED_SECONDARY"
      warn "Propagation in progress — wait a few minutes"
    fi
  else
    warn "Domain not yet resolving. Add A Record: $DOMAIN → $EXTERNAL_IP"
    warn "  nslookup $DOMAIN $DNS_PRIMARY   # verify after adding"
    warn "  nslookup $DOMAIN $DNS_SECONDARY  # verify after adding"
  fi
else
  warn "dig not installed — run: sudo apt-get install dnsutils"
  warn "Manual check: nslookup $DOMAIN $DNS_PRIMARY"
fi

# ── NEW Section 8: HTTPS Endpoint Verification ────────────────────────────────
title "HTTPS Endpoint Verification — https://$DOMAIN"

HTTPS_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 15 \
  "https://$DOMAIN/health" 2>/dev/null || echo "000")

HTTPS_PING=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 15 \
  "https://$DOMAIN/api/ping" 2>/dev/null || echo "000")

HTTPS_API_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 15 \
  "https://$DOMAIN/api/health" 2>/dev/null || echo "000")

log "https://$DOMAIN/health       → HTTP $HTTPS_HEALTH   (expect 200)"
log "https://$DOMAIN/api/ping     → HTTP $HTTPS_PING   (expect 200)"
log "https://$DOMAIN/api/health   → HTTP $HTTPS_API_HEALTH   (expect 200)"

[ "$HTTPS_HEALTH"     = "200" ] && log "/health passed ✓"     || warn "/health returned $HTTPS_HEALTH (DNS or TLS may still be propagating)"
[ "$HTTPS_PING"       = "200" ] && log "/api/ping passed ✓"   || warn "/api/ping returned $HTTPS_PING"
[ "$HTTPS_API_HEALTH" = "200" ] && log "/api/health passed ✓" || warn "/api/health returned $HTTPS_API_HEALTH (DB may still be initializing)"

# ── NEW Section 9: TLS Certificate Inspection ─────────────────────────────────
title "TLS Certificate — https://$DOMAIN"

if command -v openssl >/dev/null 2>&1; then
  CERT_INFO=$(echo | openssl s_client \
    -connect "$DOMAIN:443" \
    -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)

  if [ -n "$CERT_INFO" ]; then
    log "TLS certificate info:"
    echo "$CERT_INFO" | while IFS= read -r line; do log "  $line"; done
    echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | while IFS= read -r line; do log "  Expiry: $line"; done || true
  else
    warn "Cannot retrieve TLS cert — HTTPS not yet active or DNS not propagated"
  fi
else
  warn "openssl not installed — skipping TLS cert check"
fi

# ── NEW Section 10: cert-manager Certificate Resource ─────────────────────────
title "cert-manager Certificate Status"

CERT_READY=$(kubectl get certificate app-tls-cert -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")

if [ "$CERT_READY" = "True" ]; then
  log "cert-manager Certificate app-tls-cert: Ready=True ✓"
elif [ "$CERT_READY" = "NotFound" ]; then
  warn "Certificate resource not found. Apply cert-manager issuer and Ingress:"
  warn "  kubectl apply -f cert-manager/cluster-issuer.yaml"
  warn "  kubectl apply -f k8s/ingress.yaml -n $NAMESPACE"
else
  warn "Certificate Ready=$CERT_READY — may still be issuing (HTTP-01 challenge in progress)"
  warn "Debug: kubectl describe certificate app-tls-cert -n $NAMESPACE"
  warn "Debug: kubectl get challenges -n $NAMESPACE"
fi

# ── NEW Section 11: HTTP → HTTPS Redirect ─────────────────────────────────────
title "HTTP → HTTPS Redirect Test"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "http://$DOMAIN" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "308" ]; then
  log "HTTP → HTTPS redirect active: HTTP $HTTP_CODE ✓"
elif [ "$HTTP_CODE" = "000" ]; then
  warn "Cannot connect on HTTP (DNS may not be propagated yet)"
else
  warn "HTTP returned $HTTP_CODE (expected 301 or 308)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
title "Summary"
log "Vault pod      : ${VAULT_POD:-not found}"
log "Backend pods   : $BACKEND_READY ready"
log "Frontend pods  : $FRONTEND_READY ready"
[ -n "$EXTERNAL_IP" ] && log "External IP    : $EXTERNAL_IP" || warn "External IP    : pending"
log "Domain         : https://$DOMAIN"
log "DNS (8.8.8.8)  : ${RESOLVED_PRIMARY:-<pending>}"
log "DNS (8.8.4.4)  : ${RESOLVED_SECONDARY:-<pending>}"
log "TLS Cert       : Ready=$CERT_READY"
log "HTTPS /health  : HTTP $HTTPS_HEALTH"
echo ""
log "✅ Verification complete!"
log "For full DNS validation: bash scripts/dns-validate.sh"
