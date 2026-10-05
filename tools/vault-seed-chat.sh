#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-chat.sh — Seed kv/disinto/chat into Vault KV
#
# Part of issue #678. Seeds kv/disinto/chat with the secrets the edge
# caddy and snapshot tasks render:
#
#   forge_pat    — admin PAT (FORGE_PAT)
#   nomad_token  — scoped ACL token (NOMAD_TOKEN), or left unset when absent
#
# Idempotency contract:
#   - Reads from .env (FORGE_PAT, NOMAD_TOKEN) or from environment
#     variables of the same names. Present keys overwrite existing KV values.
#   - Missing keys are skipped with a warning (not a hard failure).
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
    printf 'Seed kv/disinto/chat from .env into Vault KV.\n'
    printf 'Idempotent: present keys overwrite existing values;\n'
    printf 'missing keys are skipped. Sibling fields are preserved.\n\n'
    printf 'Reads from .env (FORGE_PAT, NOMAD_TOKEN) or\n'
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
    done < <(grep -E "^${key}=" "$env_file" 2>/dev/null || true)
  fi
}

forge_pat="$(_resolve_val "FORGE_PAT")"
nomad_token="$(_resolve_val "NOMAD_TOKEN")"

# ── Step 3/3: merge into KV and write ────────────────────────────────────────
log "── Step 3/3: write to ${KV_API_PATH} ──"

# Read existing document and merge — KV v2 POST replaces the full data
# document, so preserve any sibling fields.
existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" || true
existing_data="{}"
[ -n "$existing_raw" ] && existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"

# Build the merged payload.
payload="$existing_data"
if [ -n "$forge_pat" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$forge_pat" '.forge_pat = $v')"
fi
if [ -n "$nomad_token" ]; then
  payload="$(printf '%s' "$payload" | jq --arg v "$nomad_token" '.nomad_token = $v')"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] ${KV_API_PATH}: would write"
  if [ -n "$forge_pat" ]; then log "[dry-run]   forge_pat"; fi
  if [ -n "$nomad_token" ]; then log "[dry-run]   nomad_token"; fi
  log "done — 0 keys written, skipped (dry-run)"
  exit 0
fi

payload="$(printf '%s' "$payload" | jq '{data: .}')"

if ! _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null; then
  die "failed to write ${KV_API_PATH}"
fi

# Report what was written.
written=0
[ -n "$forge_pat" ] && { log "${KV_API_PATH}: written (forge_pat)"; ((written++)) || true; }
[ -n "$nomad_token" ] && { log "${KV_API_PATH}: written (nomad_token)"; ((written++)) || true; }

# Report skipped keys.
skipped=0
[ -z "$forge_pat" ] && { log "skip forge_pat (not set)"; ((skipped++)) || true; }
[ -z "$nomad_token" ] && { log "skip nomad_token (not set)"; ((skipped++)) || true; }

log "done — ${written} keys written, ${skipped} skipped"
