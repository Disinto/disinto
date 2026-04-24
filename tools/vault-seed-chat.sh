#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-chat.sh — Seed chat secrets into Vault KV
#
# Part of issue #678 (automate chat OAuth + Vault bootstrap). Seeds
# kv/disinto/chat with the secrets the edge.hcl caddy task template renders:
#
#   forge_pat          — admin PAT for the forge-api MCP
#   nomad_token        — scoped ACL token (or placeholder when ACL disabled)
#   oauth_client_id    — Forgejo OAuth2 app client ID for disinto-chat
#   oauth_client_secret — Forgejo OAuth2 app client secret
#   forward_auth_secret — random >=32-byte value for Caddy forward_auth
#
# Idempotency contract:
#   - Reads from .env (FORGE_PAT, NOMAD_TOKEN, CHAT_OAUTH_CLIENT_ID,
#     CHAT_OAUTH_CLIENT_SECRET) or from environment variables of the same
#     names. Present keys overwrite existing KV values.
#   - Missing keys are skipped with a warning (not a hard failure).
#   - forward_auth_secret is generated fresh on first run (if not already
#     in KV) and never overwritten on re-run.
#   - Existing sibling fields in the KV document are preserved (merge, not
#     clobber).
#
# Usage:
#   tools/vault-seed-chat.sh
#   tools/vault-seed-chat.sh --dry-run
#
# Requires:
#   - VAULT_ADDR  (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN (env OR /etc/vault.d/root.token)
#   - curl, jq, openssl
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

KV_MOUNT="kv"
KV_LOGICAL_PATH="disinto/chat"
KV_API_PATH="${KV_MOUNT}/data/${KV_LOGICAL_PATH}"

log() { printf '[vault-seed-chat] %s\n' "$*"; }
die() { printf '[vault-seed-chat] ERROR: %s\n' "$*" >&2; exit 1; }

# Strip surrounding single/double quotes from a value.
_strip_quote() {
  local v="$1"
  case "$v" in
    \'*\'|\"*\") v="${v:1:${#v}-2}" ;;
  esac
  printf '%s' "$v"
}

# ── Flag parsing ─────────────────────────────────────────────────────────────
DRY_RUN=0
case "$#:${1-}" in
  0:)
    ;;
  1:--dry-run)
    DRY_RUN=1
    ;;
  1:-h|1:--help)
    printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
    printf 'Seed chat secrets from .env into Vault KV at\n'
    printf 'kv/disinto/chat. Idempotent: present keys overwrite\n'
    printf 'existing values; missing keys are skipped. forward_auth\n'
    printf 'secret is generated on first run only.\n\n'
    printf 'Reads from .env (FORGE_PAT, NOMAD_TOKEN,\n'
    printf 'CHAT_OAUTH_CLIENT_ID, CHAT_OAUTH_CLIENT_SECRET) or\n'
    printf 'environment variables of the same names.\n\n'
    printf '  --dry-run   Print planned actions without writing.\n'
    exit 0
    ;;
  *)
    die "invalid arguments: $*  (try --help)"
    ;;
esac

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

_hvault_default_env

[ -n "${VAULT_ADDR:-}" ] \
  || die "VAULT_ADDR unset — e.g. export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/3: ensure kv/ mount exists and is KV v2 ──────────────────────────
log "── Step 1/3: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "[vault-seed-chat]" \
  || die "KV mount check failed"

# ── Step 2/3: read values from env / .env ────────────────────────────────────
log "── Step 2/3: read secrets from environment / .env ──"

env_file="${REPO_ROOT}/.env"

# Resolve a value: direct env var > .env entry > empty.
_resolve_val() {
  local key="$1"
  # Direct env var takes precedence.
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return
  fi
  # Fall back to .env if present.
  if [ -f "$env_file" ]; then
    while IFS='=' read -r k v; do
      [[ "$k" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$k" ]] && continue
      k="$(printf '%s' "$k" | xargs)"
      if [ "$k" = "$key" ]; then
        _strip_quote "$v"
        return
      fi
    done < <(grep -E "^[A-Za-z_][A-Za-z0-9_]*=${key}=" "$env_file" 2>/dev/null || true)
  fi
}

forge_pat="$(_resolve_val "FORGE_PAT")"
nomad_token="$(_resolve_val "NOMAD_TOKEN")"
oauth_client_id="$(_resolve_val "CHAT_OAUTH_CLIENT_ID")"
oauth_client_secret="$(_resolve_val "CHAT_OAUTH_CLIENT_SECRET")"

# forward_auth_secret: generate if not already in KV (never overwrite).
forward_auth_secret=""
if [ -n "${FORWARD_AUTH_SECRET:-}" ]; then
  forward_auth_secret="$FORWARD_AUTH_SECRET"
elif [ -f "$env_file" ]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$k" ]] && continue
    k="$(printf '%s' "$k" | xargs)"
    if [ "$k" = "FORWARD_AUTH_SECRET" ]; then
      forward_auth_secret="$(_strip_quote "$v")"
      break
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null || true)
fi

# ── Step 3/3: merge into KV and write ────────────────────────────────────────
log "── Step 3/3: write to ${KV_API_PATH} ──"

# Read existing document and merge — KV v2 POST replaces the full data
# document, so preserve any sibling fields.
existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" || true
existing_data="{}"
[ -n "$existing_raw" ] && existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"

# Determine if forward_auth_secret already exists in KV (never overwrite).
existing_fas="$(printf '%s' "$existing_data" | jq -r '.forward_auth_secret // ""')"
if [ -z "$forward_auth_secret" ] && [ -n "$existing_fas" ]; then
  forward_auth_secret="$existing_fas"
fi

# Build the merged payload.
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

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] ${KV_API_PATH}: would write"
  if [ -n "$forge_pat" ]; then log "[dry-run]   forge_pat"; fi
  if [ -n "$nomad_token" ]; then log "[dry-run]   nomad_token"; fi
  if [ -n "$oauth_client_id" ]; then log "[dry-run]   oauth_client_id"; fi
  if [ -n "$oauth_client_secret" ]; then log "[dry-run]   oauth_client_secret"; fi
  if [ -n "$forward_auth_secret" ]; then log "[dry-run]   forward_auth_secret"; fi
  log "done — 0 keys written, skipped (dry-run)"
  exit 0
fi

# Generate forward_auth_secret if still missing and we're doing a live run.
if [ -z "$forward_auth_secret" ]; then
  forward_auth_secret="$(openssl rand -base64 48 | tr -d '\n')"
  payload="$(printf '%s' "$payload" | jq --arg v "$forward_auth_secret" '.forward_auth_secret = $v')"
  log "generated forward_auth_secret (48 bytes, base64)"
fi

payload="$(printf '%s' "$payload" | jq '{data: .}')"

if ! _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null; then
  die "failed to write ${KV_API_PATH}"
fi

# Report what was written.
written=0
[ -n "$forge_pat" ] && { log "${KV_API_PATH}: written (forge_pat)"; ((written++)) || true; }
[ -n "$nomad_token" ] && { log "${KV_API_PATH}: written (nomad_token)"; ((written++)) || true; }
[ -n "$oauth_client_id" ] && { log "${KV_API_PATH}: written (oauth_client_id)"; ((written++)) || true; }
[ -n "$oauth_client_secret" ] && { log "${KV_API_PATH}: written (oauth_client_secret)"; ((written++)) || true; }
[ -n "$forward_auth_secret" ] && { log "${KV_API_PATH}: written (forward_auth_secret)"; ((written++)) || true; }

# Report skipped keys.
skipped=0
[ -z "$forge_pat" ] && { log "skip forge_pat (not set)"; ((skipped++)) || true; }
[ -z "$nomad_token" ] && { log "skip nomad_token (not set)"; ((skipped++)) || true; }
[ -z "$oauth_client_id" ] && { log "skip oauth_client_id (not set)"; ((skipped++)) || true; }
[ -z "$oauth_client_secret" ] && { log "skip oauth_client_secret (not set)"; ((skipped++)) || true; }

log "done — ${written} keys written, ${skipped} skipped"
