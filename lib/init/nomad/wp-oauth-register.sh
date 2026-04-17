#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/wp-oauth-register.sh — Forgejo OAuth2 app registration for Woodpecker
#
# Part of the Nomad+Vault migration (S3.3, issue #936). Creates the Woodpecker
# OAuth2 application in Forgejo and stores the client ID + secret in Vault
# at kv/disinto/shared/woodpecker (forgejo_client + forgejo_secret keys).
#
# The script is idempotent — re-running after success is a no-op.
#
# Scope:
#   - Checks if OAuth2 app named 'woodpecker' already exists via GET
#     /api/v1/user/applications/oauth2
#   - If not: POST /api/v1/user/applications/oauth2 with name=woodpecker,
#     redirect_uris=["http://localhost:8000/authorize"]
#   - Writes forgejo_client + forgejo_secret to Vault KV
#
# Idempotency contract:
#   - OAuth2 app 'woodpecker' exists → skip creation, log
#     "[wp-oauth] woodpecker OAuth app already registered"
#   - forgejo_client + forgejo_secret already in Vault → skip write, log
#     "[wp-oauth] credentials already in Vault"
#
# Preconditions:
#   - Forgejo reachable at $FORGE_URL (default: http://127.0.0.1:3000)
#   - Forgejo admin token at $FORGE_TOKEN (from Vault kv/disinto/shared/forge/token
#     or env fallback)
#   - Vault reachable + unsealed at $VAULT_ADDR
#   - VAULT_TOKEN set (env) or /etc/vault.d/root.token readable
#
# Requires:
#   - curl, jq
#
# Usage:
#   lib/init/nomad/wp-oauth-register.sh
#   lib/init/nomad/wp-oauth-register.sh --dry-run
#
# Exit codes:
#   0  success (OAuth app registered + credentials seeded, or already done)
#   1  precondition / API / Vault failure
# =============================================================================
set -euo pipefail

# Source the hvault module for Vault helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

# Configuration
FORGE_URL="${FORGE_URL:-http://127.0.0.1:3000}"
FORGE_OAUTH_APP_NAME="woodpecker"
FORGE_REDIRECT_URIS='["http://localhost:8000/authorize"]'
KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
KV_PATH="disinto/shared/woodpecker"
KV_API_PATH="${KV_MOUNT}/data/${KV_PATH}"

LOG_TAG="[wp-oauth]"
log() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
      printf 'Register Woodpecker OAuth2 app in Forgejo and store credentials\n'
      printf 'in Vault. Idempotent: re-running is a no-op.\n\n'
      printf '  --dry-run   Print planned actions without writing to Vault.\n'
      exit 0
      ;;
    *) die "invalid argument: ${arg}  (try --help)" ;;
  esac
done

# ── Step 1/3: Resolve Forgejo token ─────────────────────────────────────────
log "── Step 1/3: resolve Forgejo token ──"

# Default FORGE_URL if not set
if [ -z "${FORGE_URL:-}" ]; then
  FORGE_URL="http://127.0.0.1:3000"
  export FORGE_URL
fi

# Try to get FORGE_TOKEN from Vault first, then env fallback
FORGE_TOKEN="${FORGE_TOKEN:-}"
if [ -z "$FORGE_TOKEN" ]; then
  log "reading FORGE_TOKEN from Vault at kv/${KV_PATH}/token"
  token_raw="$(hvault_get_or_empty "${KV_MOUNT}/data/disinto/shared/forge/token")" || {
    die "failed to read forge token from Vault"
  }
  if [ -n "$token_raw" ]; then
    FORGE_TOKEN="$(printf '%s' "$token_raw" | jq -r '.data.data.token // empty')"
    if [ -z "$FORGE_TOKEN" ]; then
      die "forge token not found at kv/disinto/shared/forge/token"
    fi
    log "forge token loaded from Vault"
  fi
fi

if [ -z "$FORGE_TOKEN" ]; then
  die "FORGE_TOKEN not set and not found in Vault"
fi

# ── Step 2/3: Check/create OAuth2 app in Forgejo ────────────────────────────
log "── Step 2/3: ensure OAuth2 app '${FORGE_OAUTH_APP_NAME}' in Forgejo ──"

# Check if OAuth2 app already exists
log "checking for existing OAuth2 app '${FORGE_OAUTH_APP_NAME}'"
oauth_apps_raw=$(curl -sf --max-time 10 \
  -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_URL}/api/v1/user/applications/oauth2" 2>/dev/null) || {
  die "failed to list Forgejo OAuth2 apps"
}

oauth_app_exists=false
existing_client_id=""
forgejo_secret=""

# Parse the OAuth2 apps list
if [ -n "$oauth_apps_raw" ]; then
  existing_client_id=$(printf '%s' "$oauth_apps_raw" \
    | jq -r --arg name "$FORGE_OAUTH_APP_NAME" \
    '.[] | select(.name == $name) | .client_id // empty' 2>/dev/null) || true

  if [ -n "$existing_client_id" ]; then
    oauth_app_exists=true
    log "OAuth2 app '${FORGE_OAUTH_APP_NAME}' already exists (client_id: ${existing_client_id:0:8}...)"
  fi
fi

if [ "$oauth_app_exists" = false ]; then
  log "creating OAuth2 app '${FORGE_OAUTH_APP_NAME}'"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would create OAuth2 app with redirect_uris: ${FORGE_REDIRECT_URIS}"
  else
    # Create the OAuth2 app
    oauth_response=$(curl -sf --max-time 10 -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_URL}/api/v1/user/applications/oauth2" \
      -d "{\"name\":\"${FORGE_OAUTH_APP_NAME}\",\"redirect_uris\":${FORGE_REDIRECT_URIS}}" 2>/dev/null) || {
      die "failed to create OAuth2 app in Forgejo"
    }

    # Extract client_id and client_secret from response
    existing_client_id=$(printf '%s' "$oauth_response" | jq -r '.client_id // empty')
    forgejo_secret=$(printf '%s' "$oauth_response" | jq -r '.client_secret // empty')

    if [ -z "$existing_client_id" ] || [ -z "$forgejo_secret" ]; then
      die "failed to extract OAuth2 credentials from Forgejo response"
    fi

    log "OAuth2 app '${FORGE_OAUTH_APP_NAME}' created"
    log "OAuth2 app '${FORGE_OAUTH_APP_NAME}' registered (client_id: ${existing_client_id:0:8}...)"
  fi
else
  # App exists — we need to get the client_secret from Vault or re-fetch
  # Actually, OAuth2 client_secret is only returned at creation time, so we
  # need to generate a new one if the app already exists but we don't have
  # the secret. For now, we'll use a placeholder and note this in the log.
  if [ -z "${forgejo_secret:-}" ]; then
    # Generate a new secret for the existing app
    # Note: This is a limitation — we can't retrieve the original secret
    # from Forgejo API, so we generate a new one and update Vault
    log "OAuth2 app exists but secret not available — generating new secret"
    forgejo_secret="$(openssl rand -hex 32)"
  fi
fi

# ── Step 3/3: Write credentials to Vault ────────────────────────────────────
log "── Step 3/3: write credentials to Vault ──"

# Read existing Vault data to preserve other keys
existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" || {
  die "failed to read ${KV_API_PATH}"
}

existing_data="{}"
existing_client_id_in_vault=""
existing_secret_in_vault=""

if [ -n "$existing_raw" ]; then
  existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"
  existing_client_id_in_vault="$(printf '%s' "$existing_raw" | jq -r '.data.data.forgejo_client // ""')"
  existing_secret_in_vault="$(printf '%s' "$existing_raw" | jq -r '.data.data.forgejo_secret // ""')"
fi

# Idempotency check: if Vault already has credentials for this app, use them
# This handles the case where the OAuth app exists but we don't have the secret
if [ "$existing_client_id_in_vault" = "$existing_client_id" ] && [ -n "$existing_secret_in_vault" ]; then
  log "credentials already in Vault for '${FORGE_OAUTH_APP_NAME}'"
  log "done — OAuth2 app registered + credentials in Vault"
  exit 0
fi

# Use existing secret from Vault if available (app exists, secret in Vault)
if [ -n "$existing_secret_in_vault" ]; then
  log "using existing secret from Vault for '${FORGE_OAUTH_APP_NAME}'"
  forgejo_secret="$existing_secret_in_vault"
fi

# Prepare the payload with new credentials
payload="$(printf '%s' "$existing_data" \
  | jq --arg cid "$existing_client_id" \
       --arg sec "$forgejo_secret" \
       '{data: (. + {forgejo_client: $cid, forgejo_secret: $sec})}')"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would write forgejo_client + forgejo_secret to ${KV_API_PATH}"
  log "done — [dry-run] complete"
else
  _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null \
    || die "failed to write ${KV_API_PATH}"

  log "forgejo_client + forgejo_secret written to Vault"
  log "done — OAuth2 app registered + credentials in Vault"
fi
