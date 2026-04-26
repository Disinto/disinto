#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/chat-init.sh — Forgejo OAuth + Vault KV seed for chat
#
# Part of issue #678 (automate chat OAuth + Vault bootstrap). Runs as a
# post-deploy step during `disinto init --backend=nomad --with edge`.
#
# What it does:
#   1. Creates (or reuses) the Forgejo OAuth2 app "disinto-chat" with
#      the correct redirect URI for the edge tunnel FQDN.
#   2. Seeds kv/disinto/chat with:
#        oauth_client_id / oauth_client_secret  — from the OAuth app
#        forge_pat                               — admin PAT (from FORGE_TOKEN)
#        nomad_token                             — placeholder (set when ACL enabled)
#        forward_auth_secret                     — random 48-byte value
#   3. If Nomad ACL is enabled: applies chat-ops.hcl policy, creates a
#      client token, and stores it in Vault.
#
# Idempotency contract:
#   - OAuth app: checks for existing "disinto-chat" app; reuses if present.
#   - KV writes: merge-style (preserves sibling fields). forward_auth_secret
#     is generated once and never overwritten.
#   - Nomad ACL: policy apply is idempotent; token is created once (skipped
#     on re-run if a token already exists in KV).
#
# Environment:
#   FORGE_URL           — Forgejo base URL (required)
#   FORGE_TOKEN         — Forgejo admin PAT (required)
#   FORGE_ADMIN_PASS    — Forgejo admin password (for PAT creation)
#   EDGE_TUNNEL_FQDN    — Edge tunnel FQDN (default: localhost)
#   EDGE_TUNNEL_FQDN_CHAT — subdomain for chat (default: chat.<FQDN>)
#   EDGE_ROUTING_MODE   — "subpath" or "subdomain" (default: subpath)
#   VAULT_ADDR          — Vault address (default: http://127.0.0.1:8200)
#   VAULT_TOKEN         — Vault token (env or /etc/vault.d/root.token)
#
# Usage:
#   lib/init/nomad/chat-init.sh
#
# Exit codes:
#   0  success
#   1  precondition / API failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../../../../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

# ── Configuration ────────────────────────────────────────────────────────────
FORGE_URL="${FORGE_URL:-}"
FORGE_TOKEN="${FORGE_TOKEN:-}"
FORGE_ADMIN_PASS="${FORGE_ADMIN_PASS:-}"
EDGE_TUNNEL_FQDN="${EDGE_TUNNEL_FQDN:-localhost}"
EDGE_TUNNEL_FQDN_CHAT="${EDGE_TUNNEL_FQDN_CHAT:-}"
EDGE_ROUTING_MODE="${EDGE_ROUTING_MODE:-subpath}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

log() { printf '[chat-init] %s\n' "$*"; }
die() { printf '[chat-init] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

[ -n "$FORGE_URL" ] \
  || die "FORGE_URL is not set"
[ -n "$FORGE_TOKEN" ] \
  || die "FORGE_TOKEN is not set"

_hvault_default_env
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/3: Create Forgejo OAuth2 app for disinto-chat ────────────────────
log "── Step 1/3: Forgejo OAuth2 app for disinto-chat ──"

# Build redirect URI.
if [ "$EDGE_ROUTING_MODE" = "subdomain" ]; then
  chat_redirect_uri="https://${EDGE_TUNNEL_FQDN_CHAT:-chat.${EDGE_TUNNEL_FQDN}}/oauth/callback"
else
  chat_redirect_uri="https://${EDGE_TUNNEL_FQDN}/chat/oauth/callback"
fi

oauth_app_name="disinto-chat"

# Check for existing app.
existing_app_json="$(curl -sf --max-time 10 \
  -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_URL}/api/v1/user/applications/oauth2" 2>/dev/null)" || existing_app_json=""

oauth_client_id=""
oauth_client_secret=""

if [ -n "$existing_app_json" ]; then
  existing_id="$(printf '%s' "$existing_app_json" \
    | jq -r --arg name "$oauth_app_name" \
      '.[] | select(.name == $name) | .client_id // empty' 2>/dev/null)" || true
  if [ -n "$existing_id" ]; then
    oauth_client_id="$existing_id"
    log "OAuth2 app '${oauth_app_name}' already exists (client_id=${oauth_client_id})"
  fi
fi

# Create the app if it doesn't exist.
if [ -z "$oauth_client_id" ]; then
  log "creating OAuth2 app '${oauth_app_name}' (redirect=${chat_redirect_uri})"
  create_resp="$(curl -sf --max-time 30 -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_URL}/api/v1/user/applications/oauth2" \
    -d "{\"name\":\"${oauth_app_name}\",\"redirect_uris\":[\"${chat_redirect_uri}\"],\"confidential_client\":true}" \
    2>/dev/null)" || die "failed to create OAuth2 app '${oauth_app_name}'"

  oauth_client_id="$(printf '%s' "$create_resp" | jq -r '.client_id // empty')" || \
    die "failed to extract client_id from OAuth2 app creation response"
  oauth_client_secret="$(printf '%s' "$create_resp" | jq -r '.client_secret // empty')" || \
    die "failed to extract client_secret from OAuth2 app creation response"

  if [ -z "$oauth_client_id" ]; then
    die "OAuth2 app created but no client_id returned"
  fi
  log "OAuth2 app '${oauth_app_name}' created (client_id=${oauth_client_id})"
fi

# ── Step 2/3: Seed kv/disinto/chat ──────────────────────────────────────────
log "── Step 2/3: seed kv/disinto/chat ──"

KV_API_PATH="kv/data/disinto/chat"

# Ensure KV mount exists.
export DRY_RUN=0
hvault_ensure_kv_v2 "kv" "[chat-init]" \
  || die "KV mount check failed"

# Read existing document for merge.
existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" || true
existing_data="{}"
[ -n "$existing_raw" ] && existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"

# forge_pat: use FORGE_TOKEN (admin PAT) if available.
forge_pat="${FORGE_TOKEN:-}"

# nomad_token: placeholder for now; set when Nomad ACL is enabled.
nomad_token=""

# forward_auth_secret: generate if not already in KV.
existing_fas="$(printf '%s' "$existing_data" | jq -r '.forward_auth_secret // ""')"
forward_auth_secret=""
if [ -n "$existing_fas" ]; then
  forward_auth_secret="$existing_fas"
elif [ -n "${FORWARD_AUTH_SECRET:-}" ]; then
  forward_auth_secret="$FORWARD_AUTH_SECRET"
fi

# Build merged payload.
payload="$existing_data"
if [ -n "$forge_pat" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$forge_pat" '.forge_pat = $v')"
fi
if [ -n "$nomad_token" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$nomad_token" '.nomad_token = $v')"
fi
if [ -n "$oauth_client_id" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$oauth_client_id" '.oauth_client_id = $v')"
fi
if [ -n "$oauth_client_secret" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$oauth_client_secret" '.oauth_client_secret = $v')"
fi
if [ -n "$forward_auth_secret" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$forward_auth_secret" '.forward_auth_secret = $v')"
fi

# Generate forward_auth_secret if still missing.
if [ -z "$forward_auth_secret" ]; then
  forward_auth_secret="$(openssl rand -base64 48 | tr -d '\n')"
  payload="$(printf '%s' "$payload" | jq --arg v "$forward_auth_secret" '.forward_auth_secret = $v')"
  log "generated forward_auth_secret (48 bytes, base64)"
fi

payload="$(printf '%s' "$payload" | jq '{data: .}')"

if ! _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null; then
  die "failed to write ${KV_API_PATH}"
fi

log "kv/disinto/chat: written (oauth_client_id, oauth_client_secret, forge_pat${forward_auth_secret:+, forward_auth_secret})"

# ── Step 3/3: Nomad ACL policy + token (conditional) ────────────────────────
log "── Step 3/3: Nomad ACL for chat (conditional) ──"

ACL_POLICY_HCL="${REPO_ROOT}/nomad/acl-policies/chat-ops.hcl"
ACL_POLICY_NAME="chat-ops"

# Check if Nomad ACL is enabled.
# `nomad acl status` is not a valid subcommand; use `nomad acl policy list`,
# which exits 0 when ACLs are enabled and non-zero (with "ACL support
# disabled") otherwise. See issue #684.
nomad_acl_enabled=false
if command -v nomad >/dev/null 2>&1; then
  if nomad acl policy list >/dev/null 2>&1; then
    nomad_acl_enabled=true
  fi
fi

if [ "$nomad_acl_enabled" = true ] && [ -f "$ACL_POLICY_HCL" ]; then
  log "Nomad ACL is enabled — applying ${ACL_POLICY_NAME} policy"

  # Apply the policy (idempotent via PUT).
  policy_content="$(cat "$ACL_POLICY_HCL")"
  policy_payload="$(jq -n --arg p "$policy_content" '{description: "chat-Claude operator scope (#678)", policy: $p}')"

  if ! _hvault_request PUT "sys/acl/policy/${ACL_POLICY_NAME}" "$policy_payload" >/dev/null 2>&1; then
    # Try the Nomad ACL API directly.
    if command -v nomad >/dev/null 2>&1; then
      nomad acl policy apply -description "chat-Claude operator scope (#678)" \
        "$ACL_POLICY_NAME" "$ACL_POLICY_HCL" 2>/dev/null || \
        log "warning: failed to apply Nomad ACL policy ${ACL_POLICY_NAME}"
    fi
  else
    log "policy ${ACL_POLICY_NAME} applied via Vault sys API"
  fi

  # Check if a nomad_token already exists in KV.
  existing_token="$(printf '%s' "$existing_data" | jq -r '.nomad_token // ""')"

  if [ -z "$existing_token" ]; then
    log "creating Nomad ACL client token for chat-ops"
    if command -v nomad >/dev/null 2>&1; then
      token_resp="$(nomad acl token create \
        -name=chat-ops \
        -policy=chat-ops \
        -type=client \
        -format=json 2>/dev/null)" || token_resp=""

      if [ -n "$token_resp" ]; then
        new_token="$(printf '%s' "$token_resp" | jq -r '.SecretID // empty')" || new_token=""
        if [ -n "$new_token" ]; then
          # Patch the token into KV.
          existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" || true
          existing_data="{}"
          [ -n "$existing_raw" ] && existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"

          payload="$(printf '%s' "$existing_data" | jq --arg v "$new_token" '.nomad_token = $v')"
          payload="$(printf '%s' "$payload" | jq '{data: .}')"

          if _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null 2>&1; then
            log "nomad_token stored in Vault kv/disinto/chat"
          else
            log "warning: failed to store nomad_token in Vault"
          fi
        fi
      fi
    fi
  else
    log "nomad_token already present in KV — skipping token creation"
  fi
else
  if [ "$nomad_acl_enabled" = false ]; then
    log "Nomad ACL is disabled — skipping chat-ops policy + token"
  elif [ ! -f "$ACL_POLICY_HCL" ]; then
    log "chat-ops.hcl not found — skipping ACL setup"
  fi
fi

log "── done — chat OAuth + KV + ACL bootstrap complete ──"
