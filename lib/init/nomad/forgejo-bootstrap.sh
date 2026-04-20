#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/forgejo-bootstrap.sh — Bootstrap Forgejo admin user
#
# Part of the Nomad+Vault migration (S2.4, issue #1069). Creates the
# disinto-admin user in Forgejo if it doesn't exist, enabling:
#   - First-login success without manual intervention
#   - PAT generation via API (required for disinto backup import #1058)
#
# The script is idempotent — re-running after success is a no-op.
#
# Scope:
#   - Checks if user 'disinto-admin' exists via GET /api/v1/users/search
#   - If not: POST /api/v1/admin/users to create admin user
#   - Uses FORGE_ADMIN_PASS from environment (required)
#
# Idempotency contract:
#   - User 'disinto-admin' exists → skip creation, log
#     "[forgejo-bootstrap] admin user already exists"
#   - User creation fails with "user already exists" → treat as success
#
# Preconditions:
#   - Forgejo reachable at $FORGE_URL (default: http://127.0.0.1:3000)
#   - Forgejo admin token at $FORGE_TOKEN (from Vault or env)
#   - FORGE_ADMIN_PASS set (env var with admin password)
#
# Requires:
#   - curl, jq
#
# Usage:
#   lib/init/nomad/forgejo-bootstrap.sh
#   lib/init/nomad/forgejo-bootstrap.sh --dry-run
#
# Exit codes:
#   0  success (user created + ready, or already exists)
#   1  precondition / API failure
# =============================================================================
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../../../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

# Configuration
FORGE_URL="${FORGE_URL:-http://127.0.0.1:3000}"
FORGE_TOKEN="${FORGE_TOKEN:-}"
FORGE_ADMIN_USER="${DISINTO_ADMIN_USER:-disinto-admin}"
FORGE_ADMIN_EMAIL="${DISINTO_ADMIN_EMAIL:-admin@disinto.local}"

# Derive FORGE_ADMIN_PASS from common env var patterns
# Priority: explicit FORGE_ADMIN_PASS > DISINTO_FORGE_ADMIN_PASS > FORGEJO_ADMIN_PASS
FORGE_ADMIN_PASS="${FORGE_ADMIN_PASS:-${DISINTO_FORGE_ADMIN_PASS:-${FORGEJO_ADMIN_PASS:-}}}"

LOG_TAG="[forgejo-bootstrap]"
log() { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
      printf 'Bootstrap Forgejo admin user if it does not exist.\n'
      printf 'Idempotent: re-running is a no-op.\n\n'
      printf 'Environment:\n'
      printf '  FORGE_URL          Forgejo base URL (default: http://127.0.0.1:3000)\n'
      printf '  FORGE_TOKEN        Forgejo admin token (from Vault or env)\n'
      printf '  FORGE_ADMIN_PASS   Admin password (required)\n'
      printf '  DISINTO_ADMIN_USER Username for admin account (default: disinto-admin)\n'
      printf '  DISINTO_ADMIN_EMAIL Admin email (default: admin@disinto.local)\n\n'
      printf '  --dry-run   Print planned actions without modifying Forgejo.\n'
      exit 0
      ;;
    *) die "invalid argument: ${arg}  (try --help)" ;;
  esac
done

# ── Precondition checks ──────────────────────────────────────────────────────
log "── Precondition check ──"

if [ -z "$FORGE_URL" ]; then
  die "FORGE_URL is not set"
fi

if [ -z "$FORGE_ADMIN_PASS" ]; then
  die "FORGE_ADMIN_PASS is not set (required for admin user creation)"
fi

# Resolve FORGE_TOKEN from Vault if not set in env
if [ -z "$FORGE_TOKEN" ]; then
  log "reading FORGE_TOKEN from Vault at kv/disinto/shared/forge/token"
  _hvault_default_env
  token_raw="$(hvault_get_or_empty "kv/data/disinto/shared/forge/token" 2>/dev/null) || true"
  if [ -n "$token_raw" ]; then
    FORGE_TOKEN="$(printf '%s' "$token_raw" | jq -r '.data.data.token // empty' 2>/dev/null)" || true
  fi
  if [ -z "$FORGE_TOKEN" ]; then
    die "FORGE_TOKEN not set and not found in Vault"
  fi
  log "forge token loaded from Vault"
fi

# ── Step 1/2: Check if admin user already exists ─────────────────────────────
log "── Step 1/2: check if admin user '${FORGE_ADMIN_USER}' exists ──"

# Search for the user via the public API (no auth needed for search)
user_search_raw=$(curl -sf --max-time 10 \
  "${FORGE_URL}/api/v1/users/search?q=${FORGE_ADMIN_USER}&limit=1" 2>/dev/null) || {
  # If search fails (e.g., Forgejo not ready yet), we'll handle it
  log "warning: failed to search users (Forgejo may not be ready yet)"
  user_search_raw=""
}

admin_user_exists=false
user_id=""

if [ -n "$user_search_raw" ]; then
  user_id=$(printf '%s' "$user_search_raw" | jq -r '.data[0].id // empty' 2>/dev/null) || true
  if [ -n "$user_id" ]; then
    admin_user_exists=true
    log "admin user '${FORGE_ADMIN_USER}' already exists (user_id: ${user_id})"
  fi
fi

# ── Step 2/2: Create admin user if needed ────────────────────────────────────
if [ "$admin_user_exists" = false ]; then
  log "creating admin user '${FORGE_ADMIN_USER}'"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would create admin user with:"
    log "[dry-run]   username: ${FORGE_ADMIN_USER}"
    log "[dry-run]   email:    ${FORGE_ADMIN_EMAIL}"
    log "[dry-run]   admin:    true"
    log "[dry-run]   must_change_password: false"
  else
    # Create the admin user via the admin API
    create_response=$(curl -sf --max-time 30 -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_URL}/api/v1/admin/users" \
      -d "{
        \"username\": \"${FORGE_ADMIN_USER}\",
        \"email\": \"${FORGE_ADMIN_EMAIL}\",
        \"password\": \"${FORGE_ADMIN_PASS}\",
        \"admin\": true,
        \"must_change_password\": false
      }" 2>/dev/null) || {
      # Check if the error is "user already exists" (race condition on re-run)
      error_body=$(curl -s --max-time 30 -X POST \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${FORGE_URL}/api/v1/admin/users" \
        -d "{\"username\": \"${FORGE_ADMIN_USER}\", \"email\": \"${FORGE_ADMIN_EMAIL}\", \"password\": \"${FORGE_ADMIN_PASS}\", \"admin\": true, \"must_change_password\": false}" 2>/dev/null) || error_body=""

      if echo "$error_body" | grep -q '"message".*"user already exists"'; then
        log "admin user '${FORGE_ADMIN_USER}' already exists (race condition handled)"
        admin_user_exists=true
      else
        die "failed to create admin user in Forgejo: ${error_body:-unknown error}"
      fi
    }

    # Extract user_id from response
    user_id=$(printf '%s' "$create_response" | jq -r '.id // empty' 2>/dev/null) || true
    if [ -n "$user_id" ]; then
      admin_user_exists=true
      log "admin user '${FORGE_ADMIN_USER}' created (user_id: ${user_id})"
    else
      die "failed to extract user_id from Forgejo response"
    fi
  fi
else
  log "admin user '${FORGE_ADMIN_USER}' already exists — skipping creation"
fi

# ── Step 3/3: Verify user was created and is admin ───────────────────────────
log "── Step 3/3: verify admin user is properly configured ──"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would verify admin user configuration"
  log "done — [dry-run] complete"
else
  # Verify the user exists and is admin
  verify_response=$(curl -sf --max-time 10 \
    -u "${FORGE_ADMIN_USER}:${FORGE_ADMIN_PASS}" \
    "${FORGE_URL}/api/v1/user" 2>/dev/null) || {
    die "failed to verify admin user credentials"
  }

  is_admin=$(printf '%s' "$verify_response" | jq -r '.is_admin // false' 2>/dev/null) || true
  login=$(printf '%s' "$verify_response" | jq -r '.login // empty' 2>/dev/null) || true

  if [ "$is_admin" != "true" ]; then
    die "admin user '${FORGE_ADMIN_USER}' is not marked as admin"
  fi

  if [ "$login" != "$FORGE_ADMIN_USER" ]; then
    die "admin user login mismatch: expected '${FORGE_ADMIN_USER}', got '${login}'"
  fi

  log "admin user verified: login=${login}, is_admin=${is_admin}"
  log "done — Forgejo admin user is ready"
fi

exit 0
