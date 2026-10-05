#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/chat-init.sh — Vault KV seed for kv/disinto/chat
#
# Part of issue #678. Runs as a post-deploy step during
# `disinto init --backend=nomad --with edge`.
#
# What it does:
#   1. Seeds kv/disinto/chat with:
#        forge_pat    — admin PAT (from FORGE_TOKEN)
#        nomad_token  — placeholder (set when ACL is enabled)
#   2. If Nomad ACL is enabled: applies chat-ops.hcl, creates a client
#      token, and stores it in Vault as nomad_token.
#
# Idempotency contract:
#   - KV writes: merge-style (preserves sibling fields).
#   - Nomad ACL: policy apply is idempotent; token is created once (skipped
#     on re-run if a token already exists in KV).
#
# Environment:
#   FORGE_TOKEN  — Forgejo admin PAT (required)
#   VAULT_ADDR   — Vault address (default: http://127.0.0.1:8200)
#   VAULT_TOKEN  — Vault token (env or /etc/vault.d/root.token)
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
FORGE_TOKEN="${FORGE_TOKEN:-}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

log() { printf '[chat-init] %s\n' "$*"; }
die() { printf '[chat-init] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

[ -n "$FORGE_TOKEN" ] \
  || die "FORGE_TOKEN is not set"

_hvault_default_env
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/2: Seed kv/disinto/chat ──────────────────────────────────────────
log "── Step 1/2: seed kv/disinto/chat ──"

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

# Build merged payload.
payload="$existing_data"
if [ -n "$forge_pat" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$forge_pat" '.forge_pat = $v')"
fi
if [ -n "$nomad_token" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$nomad_token" '.nomad_token = $v')"
fi

payload="$(printf '%s' "$payload" | jq '{data: .}')"

if ! _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null; then
  die "failed to write ${KV_API_PATH}"
fi

log "kv/disinto/chat: written (forge_pat)"

# ── Step 2/2: Nomad ACL policy + token (conditional) ────────────────────────
log "── Step 2/2: Nomad ACL for chat (conditional) ──"

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

  # Apply the policy via Nomad ACL API (idempotent).
  if command -v nomad >/dev/null 2>&1; then
    nomad acl policy apply -description "chat-Claude operator scope (#678)" \
      "$ACL_POLICY_NAME" "$ACL_POLICY_HCL" 2>/dev/null || \
      log "warning: failed to apply Nomad ACL policy ${ACL_POLICY_NAME}"
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

log "── done — kv/disinto/chat seeded ──"
