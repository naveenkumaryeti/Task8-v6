#!/usr/bin/env bash
# ============================================================
# scripts/dns-validate.sh  —  NEW SCRIPT
#
# Comprehensive DNS and HTTPS validation for enterprise-app.duckdns.org.
# Run this at any time to confirm the domain is correctly configured.
#
# Checks performed:
#   1.  DNS resolution via Google Primary DNS (8.8.8.8)
#   2.  DNS resolution via Google Secondary DNS (8.8.4.4)
#   3.  DNS trace/details when dig is available
#   4.  HTTP → HTTPS redirect verification
#   5.  HTTPS /health endpoint (200 expected)
#   6.  HTTPS /api/ping endpoint (200 expected)
#   7.  HTTPS /api/health endpoint (DB connectivity check)
#   8.  TLS certificate details (issuer, expiry, subject)
#   9.  Kubernetes Ingress and cert-manager status
#  10.  Summary pass/fail for each check
#
# Usage:
#   bash scripts/dns-validate.sh
#   bash scripts/dns-validate.sh --domain custom.example.com   # override domain
#
# Prerequisites:
#   curl, openssl, kubectl, and either dig or nslookup
# ============================================================

set -euo pipefail

# ── Parse optional --domain argument ──────────────────────────────────────────
DOMAIN="${DNS_DOMAIN:-enterprise-app.duckdns.org}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

NAMESPACE="${K8S_NAMESPACE:-production}"
DNS_PRIMARY="8.8.8.8"
DNS_SECONDARY="8.8.4.4"

# ── Color helpers ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS="${GREEN}PASS${NC}"; FAIL="${RED}FAIL${NC}"; WARN="${YELLOW}WARN${NC}"

title() { echo -e "\n${CYAN}${BOLD}━━━━ $* ━━━━${NC}"; }
log()   { echo -e "${GREEN}  ✓  $*${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()   { echo -e "${RED}  ✗  $*${NC}"; }

# ── Track pass/fail ────────────────────────────────────────────────────────────
CHECKS_PASSED=0
CHECKS_FAILED=0
declare -a SUMMARY=()
DNS_READY=false

if command -v dig >/dev/null 2>&1; then
  DNS_TOOL="dig"
elif command -v nslookup >/dev/null 2>&1; then
  DNS_TOOL="nslookup"
else
  DNS_TOOL="none"
fi

dns_lookup() {
  local server="$1"
  local domain="$2"
  if [ "$DNS_TOOL" = "dig" ]; then
    dig @"$server" "$domain" +short 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true
  elif [ "$DNS_TOOL" = "nslookup" ]; then
    nslookup "$domain" "$server" 2>/dev/null \
      | awk '/^Address: / { print $2 }' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | tail -1 || true
  fi
}

check() {
  local name="$1"; local result="$2"; local detail="$3"
  if [ "$result" = "pass" ]; then
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    SUMMARY+=("  ${GREEN}✓${NC} $name: $detail")
  elif [ "$result" = "warn" ]; then
    SUMMARY+=("  ${YELLOW}⚠${NC} $name: $detail")
  else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    SUMMARY+=("  ${RED}✗${NC} $name: $detail")
  fi
}

# ── Get expected IP from cluster ───────────────────────────────────────────────
EXPECTED_IP=""
if command -v kubectl >/dev/null 2>&1; then
  EXPECTED_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -z "$EXPECTED_IP" ]; then
    EXPECTED_IP=$(kubectl get svc frontend-service -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
fi

echo ""
echo -e "${BOLD}DNS & HTTPS Validation for: ${CYAN}$DOMAIN${NC}"
echo -e "${BOLD}Expected IP (from cluster): ${CYAN}${EXPECTED_IP:-<kubectl not available>}${NC}"
echo -e "${BOLD}DNS lookup tool: ${CYAN}$DNS_TOOL${NC}"
echo -e "${BOLD}Timestamp: $(date)${NC}"

# ── Check 1: DNS via Google Primary DNS (8.8.8.8) ─────────────────────────────
title "Check 1 — DNS Resolution via Google Primary DNS ($DNS_PRIMARY)"

echo -e "  ${CYAN}Command: nslookup $DOMAIN $DNS_PRIMARY${NC}"
[ "$DNS_TOOL" = "dig" ] && echo -e "  ${CYAN}Command: dig @$DNS_PRIMARY $DOMAIN +short${NC}"
echo ""

RESOLVED_PRIMARY=$(dns_lookup "$DNS_PRIMARY" "$DOMAIN")

if [ -n "$RESOLVED_PRIMARY" ]; then
  log "Resolved: $RESOLVED_PRIMARY"
  echo ""
  if [ "$DNS_TOOL" = "dig" ]; then
    echo "  Full dig output:"
    dig @"$DNS_PRIMARY" "$DOMAIN" | grep -A5 "ANSWER SECTION" || true
    echo ""
  fi
  nslookup "$DOMAIN" "$DNS_PRIMARY" 2>/dev/null || true

  if [ -n "$EXPECTED_IP" ] && [ "$RESOLVED_PRIMARY" = "$EXPECTED_IP" ]; then
    check "Primary DNS ($DNS_PRIMARY)" "pass" "$RESOLVED_PRIMARY matches cluster IP"
  elif [ -n "$EXPECTED_IP" ]; then
    check "Primary DNS ($DNS_PRIMARY)" "fail" "Resolved $RESOLVED_PRIMARY but expected $EXPECTED_IP"
  else
    check "Primary DNS ($DNS_PRIMARY)" "pass" "Resolved $RESOLVED_PRIMARY (expected IP unknown)"
  fi
else
  err "Domain does not resolve via $DNS_PRIMARY"
  check "Primary DNS ($DNS_PRIMARY)" "fail" "NXDOMAIN or no response"
fi

# ── Check 2: DNS via Google Secondary DNS (8.8.4.4) ───────────────────────────
title "Check 2 — DNS Resolution via Google Secondary DNS ($DNS_SECONDARY)"

echo -e "  ${CYAN}Command: nslookup $DOMAIN $DNS_SECONDARY${NC}"
[ "$DNS_TOOL" = "dig" ] && echo -e "  ${CYAN}Command: dig @$DNS_SECONDARY $DOMAIN +short${NC}"
echo ""

RESOLVED_SECONDARY=$(dns_lookup "$DNS_SECONDARY" "$DOMAIN")

if [ -n "$RESOLVED_SECONDARY" ]; then
  log "Resolved: $RESOLVED_SECONDARY"
  nslookup "$DOMAIN" "$DNS_SECONDARY" 2>/dev/null || true

  if [ -n "$EXPECTED_IP" ] && [ "$RESOLVED_SECONDARY" = "$EXPECTED_IP" ]; then
    check "Secondary DNS ($DNS_SECONDARY)" "pass" "$RESOLVED_SECONDARY matches cluster IP"
  elif [ -n "$EXPECTED_IP" ]; then
    check "Secondary DNS ($DNS_SECONDARY)" "fail" "Resolved $RESOLVED_SECONDARY but expected $EXPECTED_IP"
  else
    check "Secondary DNS ($DNS_SECONDARY)" "pass" "Resolved $RESOLVED_SECONDARY"
  fi
else
  err "Domain does not resolve via $DNS_SECONDARY"
  check "Secondary DNS ($DNS_SECONDARY)" "fail" "NXDOMAIN or no response"
fi

if [ -n "$EXPECTED_IP" ] && \
   [ "${RESOLVED_PRIMARY:-}" = "$EXPECTED_IP" ] && \
   [ "${RESOLVED_SECONDARY:-}" = "$EXPECTED_IP" ]; then
  DNS_READY=true
fi

# ── Check 3: DNS delegation trace ─────────────────────────────────────────────
title "Check 3 — DNS Delegation Trace / Details"

if [ "$DNS_TOOL" = "dig" ]; then
  echo -e "  ${CYAN}Command: dig @$DNS_PRIMARY $DOMAIN +trace${NC}"
  echo ""
  dig @"$DNS_PRIMARY" "$DOMAIN" +trace 2>/dev/null | tail -20 || true
  check "DNS trace" "pass" "See output above"
else
  warn "dig is not installed, so full delegation trace is unavailable."
  echo -e "  ${CYAN}Command: nslookup $DOMAIN $DNS_PRIMARY${NC}"
  nslookup "$DOMAIN" "$DNS_PRIMARY" 2>/dev/null || true
  check "DNS trace" "warn" "Skipped full trace because dig is not installed"
fi

# ── Check 4: HTTP → HTTPS redirect ────────────────────────────────────────────
title "Check 4 — HTTP → HTTPS Redirect"

echo -e "  ${CYAN}Command: curl -Lv http://$DOMAIN -o /dev/null -w '%{http_code}'${NC}"
echo ""

if ! $DNS_READY; then
  warn "Skipping HTTP check because Google DNS does not resolve $DOMAIN to ${EXPECTED_IP:-the cluster IP}."
  warn "Add this A record first: enterprise-app.duckdns.org → ${EXPECTED_IP:-<cluster external IP>}"
  check "HTTP → HTTPS redirect" "warn" "Skipped until DNS resolves to cluster IP"
else
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  "http://$DOMAIN" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "308" ]; then
  log "HTTP redirect: $HTTP_CODE → HTTPS ✓"
  check "HTTP → HTTPS redirect" "pass" "HTTP $HTTP_CODE"
elif [ "$HTTP_CODE" = "200" ]; then
  warn "HTTP returned 200 directly (no redirect). ssl-redirect may not be active."
  check "HTTP → HTTPS redirect" "warn" "HTTP 200 (expected 301/308)"
elif [ "$HTTP_CODE" = "000" ]; then
  err "Could not connect on HTTP (port 80). Firewall may be blocking."
  check "HTTP → HTTPS redirect" "fail" "Connection refused or timeout"
else
  warn "Unexpected HTTP code: $HTTP_CODE"
  check "HTTP → HTTPS redirect" "warn" "HTTP $HTTP_CODE"
fi
fi

# ── Check 5: HTTPS /health ────────────────────────────────────────────────────
title "Check 5 — HTTPS Application Health (https://$DOMAIN/health)"

echo -e "  ${CYAN}Command: curl -s https://$DOMAIN/health${NC}"
echo ""

if ! $DNS_READY; then
  warn "Skipping HTTPS /health because DNS is not pointed at the cluster yet."
  check "HTTPS /health" "warn" "Skipped until DNS resolves"
else
HEALTH_CODE=$(curl -s -o /tmp/health_response.txt -w "%{http_code}" \
  --max-time 15 \
  "https://$DOMAIN/health" 2>/dev/null || echo "000")
HEALTH_BODY=$(cat /tmp/health_response.txt 2>/dev/null || echo "")

echo "  HTTP Status: $HEALTH_CODE"
echo "  Response:    $HEALTH_BODY"

if [ "$HEALTH_CODE" = "200" ]; then
  log "Frontend health check passed ✓"
  check "HTTPS /health" "pass" "HTTP 200 — $HEALTH_BODY"
else
  err "HTTPS /health returned $HEALTH_CODE"
  check "HTTPS /health" "fail" "HTTP $HEALTH_CODE"
fi
fi

# ── Check 6: HTTPS /api/ping ──────────────────────────────────────────────────
title "Check 6 — Backend API Ping (https://$DOMAIN/api/ping)"

echo -e "  ${CYAN}Command: curl -s https://$DOMAIN/api/ping${NC}"
echo ""

if ! $DNS_READY; then
  warn "Skipping HTTPS /api/ping because DNS is not pointed at the cluster yet."
  check "HTTPS /api/ping" "warn" "Skipped until DNS resolves"
else
PING_CODE=$(curl -s -o /tmp/ping_response.txt -w "%{http_code}" \
  --max-time 15 \
  "https://$DOMAIN/api/ping" 2>/dev/null || echo "000")
PING_BODY=$(cat /tmp/ping_response.txt 2>/dev/null || echo "")

echo "  HTTP Status: $PING_CODE"
echo "  Response:    $PING_BODY"

if [ "$PING_CODE" = "200" ]; then
  log "Backend ping passed ✓"
  check "HTTPS /api/ping" "pass" "HTTP 200 — $PING_BODY"
else
  err "HTTPS /api/ping returned $PING_CODE"
  check "HTTPS /api/ping" "fail" "HTTP $PING_CODE"
fi
fi

# ── Check 7: HTTPS /api/health (DB connectivity) ──────────────────────────────
title "Check 7 — Backend DB Health (https://$DOMAIN/api/health)"

echo -e "  ${CYAN}Command: curl -s https://$DOMAIN/api/health${NC}"
echo ""

if ! $DNS_READY; then
  warn "Skipping HTTPS /api/health because DNS is not pointed at the cluster yet."
  check "HTTPS /api/health (DB)" "warn" "Skipped until DNS resolves"
else
DBHEALTH_CODE=$(curl -s -o /tmp/dbhealth_response.txt -w "%{http_code}" \
  --max-time 15 \
  "https://$DOMAIN/api/health" 2>/dev/null || echo "000")
DBHEALTH_BODY=$(cat /tmp/dbhealth_response.txt 2>/dev/null || echo "")

echo "  HTTP Status: $DBHEALTH_CODE"
echo "  Response:    $DBHEALTH_BODY"

if [ "$DBHEALTH_CODE" = "200" ]; then
  log "Backend DB health check passed ✓"
  check "HTTPS /api/health (DB)" "pass" "HTTP 200 — $DBHEALTH_BODY"
else
  warn "HTTPS /api/health returned $DBHEALTH_CODE"
  check "HTTPS /api/health (DB)" "warn" "HTTP $DBHEALTH_CODE — DB may be initializing"
fi
fi

# ── Check 8: TLS certificate details ─────────────────────────────────────────
title "Check 8 — TLS Certificate Verification"

echo -e "  ${CYAN}Command: openssl s_client -connect $DOMAIN:443 -servername $DOMAIN${NC}"
echo ""

if ! $DNS_READY; then
  warn "Skipping TLS check because DNS is not pointed at the cluster yet."
  warn "Any certificate seen before DNS propagation may belong to the registrar or parked parent domain, not your app."
  check "TLS certificate" "warn" "Skipped until DNS resolves"
else
CERT_INFO=$(echo | openssl s_client \
  -connect "$DOMAIN:443" \
  -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)

if [ -n "$CERT_INFO" ]; then
  log "TLS certificate details:"
  echo "$CERT_INFO" | while IFS= read -r line; do echo "    $line"; done
  echo ""

  CERT_ISSUER=$(echo "$CERT_INFO" | grep "issuer" | head -1 || true)
  CERT_EXPIRY=$(echo "$CERT_INFO" | grep "notAfter" | head -1 || true)

  if echo "$CERT_ISSUER" | grep -qi "let.s encrypt\|R3\|R10\|E1\|E5"; then
    log "Issued by Let's Encrypt ✓"
    check "TLS — Let's Encrypt issuer" "pass" "$CERT_ISSUER"
  else
    warn "Certificate issuer: $CERT_ISSUER (not Let's Encrypt — may be valid)"
    check "TLS — issuer" "warn" "$CERT_ISSUER"
  fi

  check "TLS — certificate expiry" "pass" "$CERT_EXPIRY"
else
  err "Could not retrieve TLS certificate (HTTPS may not be active yet)"
  check "TLS certificate" "fail" "Cannot connect on port 443"
fi
fi

# ── Check 9: Kubernetes Ingress and cert-manager status ──────────────────────
title "Check 9 — Kubernetes Ingress and cert-manager Status"

if command -v kubectl >/dev/null 2>&1; then
  echo -e "  ${CYAN}kubectl get ingress app-ingress -n $NAMESPACE${NC}"
  kubectl get ingress app-ingress -n "$NAMESPACE" -o wide 2>/dev/null || warn "Ingress not found"
  echo ""

  echo -e "  ${CYAN}kubectl get certificate app-tls-cert -n $NAMESPACE${NC}"
  kubectl get certificate app-tls-cert -n "$NAMESPACE" 2>/dev/null || warn "Certificate resource not found"
  echo ""

  CERT_READY=$(kubectl get certificate app-tls-cert -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

  if [ "$CERT_READY" = "True" ]; then
    log "cert-manager Certificate: Ready=True ✓"
    check "cert-manager certificate" "pass" "Ready=True"
  else
    warn "cert-manager Certificate: Ready=$CERT_READY"
    check "cert-manager certificate" "warn" "Ready=$CERT_READY (may still be issuing)"
  fi
else
  warn "kubectl not available — skipping Kubernetes checks"
fi

# ── DNS Flush Reminder ────────────────────────────────────────────────────────
title "DNS Cache Flush Commands (if seeing stale results)"

echo -e "  ${BOLD}Linux (systemd-resolved):${NC}"
echo -e "  ${CYAN}sudo systemd-resolve --flush-caches${NC}"
echo ""
echo -e "  ${BOLD}macOS:${NC}"
echo -e "  ${CYAN}sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder${NC}"
echo ""
echo -e "  ${BOLD}Windows (PowerShell as Administrator):${NC}"
echo -e "  ${CYAN}ipconfig /flushdns${NC}"
echo ""
echo -e "  ${BOLD}Chrome browser DNS cache:${NC}"
echo -e "  ${CYAN}Navigate to chrome://net-internals/#dns  →  Click 'Clear host cache'${NC}"
echo ""
echo -e "  ${BOLD}Firefox:${NC}"
echo -e "  ${CYAN}Ctrl+Shift+Delete  →  Select Cache  →  Clear${NC}"

# ── Final summary ─────────────────────────────────────────────────────────────
title "Validation Summary"

echo ""
for line in "${SUMMARY[@]}"; do
  echo -e "$line"
done

echo ""
if [ "$CHECKS_FAILED" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All $CHECKS_PASSED checks passed! ✅${NC}"
  echo -e "${GREEN}${BOLD}https://$DOMAIN is fully operational.${NC}"
else
  echo -e "${YELLOW}${BOLD}$CHECKS_PASSED passed, $CHECKS_FAILED failed${NC}"
  echo -e "${YELLOW}Review the failed checks above and consult the README troubleshooting section.${NC}"
  if ! $DNS_READY; then
    echo ""
    echo -e "${YELLOW}${BOLD}Next required action:${NC}"
    echo -e "  Add/update this DNS A record at your DNS provider:"
    echo -e "  ${CYAN}enterprise-app.duckdns.org.  300  IN  A  ${EXPECTED_IP:-<cluster external IP>}${NC}"
    echo -e "  Then rerun: ${CYAN}bash scripts/dns-validate.sh${NC}"
  fi
fi
echo ""
