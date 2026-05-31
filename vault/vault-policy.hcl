# ============================================================
# vault-policy.hcl
#
# Vault ACL policy for the backend application pods.
# Principle of least privilege: only what the app actually reads.
#
# Apply with:
#   vault policy write app-backend-policy vault/vault-policy.hcl
#
# Verify with:
#   vault policy read app-backend-policy
#
# Test access as the role (confirm no 403 before deploying):
#   vault kv get secret/app
#   vault kv get secret/mysql
#
# Fix applied:
#   [1] PERMISSION DENIED FIX: Changed "secret/data/app/*" → "secret/data/app"
#       Wildcard /* matches children (secret/data/app/foo) but NOT the parent path itself.
#       Your Vault template reads secret/data/app (exact), so the wildcard never matched
#       and Vault returned 403 on every retry, blocking the init container indefinitely.
#       Rule: use exact paths for kv-v2 secrets; only use /* when you genuinely need
#       access to sub-paths like secret/data/app/prod, secret/data/app/staging, etc.
# ============================================================

# ── Backend Application Secrets ───────────────────────────────────────────────
# Grants read access to the exact KV-v2 paths the Vault Agent template reads:
#
#   vault.hashicorp.com/agent-inject-secret-app-creds: "secret/data/app"
#   {{- with secret "secret/data/mysql" -}}
#
# KV-v2 path anatomy:
#   secret/        → mount name
#   data/          → KV-v2 API prefix (always present for reads, even if kv put uses secret/app)
#   app            → the actual secret name

# FIX [1]: Exact path — matches secret/data/app only
path "secret/data/app" {
  capabilities = ["read"]
}

# If you later need per-environment sub-keys (secret/data/app/prod, secret/data/app/staging),
# add this alongside the exact path above — don't replace it:
# path "secret/data/app/*" {
#   capabilities = ["read", "list"]
# }

# MySQL credentials — exact path, no wildcard needed
path "secret/data/mysql" {
  capabilities = ["read"]
}

# ── Token Self-Management ─────────────────────────────────────────────────────
# Required for Vault Agent sidecar to renew its own token before expiry.
# Without this, the sidecar loses access after token_ttl (1h) and starts
# returning 403 on secret reads mid-deployment.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# ── What this policy intentionally does NOT grant ─────────────────────────────
# - No write/delete on any secret path (app pods are read-only consumers)
# - No access to secret/metadata/* (not needed for reads)
# - No access to other mounts (pki/, aws/, database/, etc.)
# - No admin paths (sys/, auth/*)
# See ci-policy.hcl for the CI/CD pipeline write policy (never give to app pods)
