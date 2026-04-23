#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-voice.sh — Seed Gemini API key from .env into Vault KV
#
# Part of issue #664 (voice interface, parent #651). Reads GEMINI_API_KEY
# from .env and writes it to kv/disinto/voice with field `gemini_api_key`,
# so that the caddy task template stanza in nomad/jobs/edge.hcl can render
# it into /secrets/gemini-api-key for the voice bridge subprocess (#662).
#
# Idempotency contract:
#   - GEMINI_API_KEY present in .env → write to kv/disinto/voice.gemini_api_key
#     (overwrites existing value — no version explosion, same-value writes
#     are cheap).
#   - GEMINI_API_KEY missing from .env → leave existing KV value alone
#     (warn, do not fail). This matches vault-seed-runner.sh's "skip missing
#     keys" semantic so a re-seed of one factory doesn't nuke keys on
#     another factory sharing the same Vault.
#
# Usage:
#   tools/vault-seed-voice.sh
#   tools/vault-seed-voice.sh --dry-run
#
# Requires:
#   - VAULT_ADDR  (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN (env OR /etc/vault.d/root.token, resolved by lib/hvault.sh)
#   - curl, jq, openssl
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

# KV v2 mount + logical path. Kept as two vars so the full API path used
# for GET/POST (which MUST include `/data/`) is built in one place.
KV_MOUNT="kv"
KV_LOGICAL_PATH="disinto/voice"
KV_API_PATH="${KV_MOUNT}/data/${KV_LOGICAL_PATH}"

log() { printf '[vault-seed-voice] %s\n' "$*"; }
die() { printf '[vault-seed-voice] ERROR: %s\n' "$*" >&2; exit 1; }

# Strip surrounding single/double quotes from a value (e.g. "abc" -> abc).
# Matches the helper used by vault-seed-runner.sh so both seeders agree
# on .env quoting semantics.
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
    printf 'Seed the Google Gemini API key from .env into Vault KV at\n'
    printf 'kv/disinto/voice.gemini_api_key. Idempotent: same-value writes\n'
    printf 'are no-ops; missing .env key leaves Vault untouched.\n\n'
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

# ── Step 1/2: ensure kv/ mount exists and is KV v2 ──────────────────────────
log "── Step 1/2: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "[vault-seed-voice]" \
  || die "KV mount check failed"

# ── Step 2/2: seed gemini_api_key ────────────────────────────────────────────
log "── Step 2/2: seed ${KV_API_PATH} ──"

env_file="${REPO_ROOT}/.env"
gemini_val=""

if [ -f "$env_file" ]; then
  # Parse .env line-by-line for GEMINI_API_KEY only (safer than sourcing).
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    key="$(printf '%s' "$key" | xargs)"
    if [ "$key" = "GEMINI_API_KEY" ]; then
      gemini_val="$(_strip_quote "$val")"
      break
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null || true)
else
  log "warning: ${env_file} not found — cannot seed gemini_api_key"
fi

if [ -z "$gemini_val" ]; then
  log "skip gemini_api_key (GEMINI_API_KEY not in .env)"
  log "done — 0 keys written, 1 skipped"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] ${KV_API_PATH}: would write gemini_api_key"
  exit 0
fi

# Read existing document and merge — KV v2 POST replaces the full data
# document, so preserve any sibling fields a future iteration of this
# script may add (or that were set manually via `vault kv put`).
existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" || true
existing_data="{}"
[ -n "$existing_raw" ] && existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"

payload="$(printf '%s' "$existing_data" \
  | jq --arg v "$gemini_val" '.gemini_api_key = $v' \
  | jq '{data: .}')"

if ! _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null; then
  die "failed to write ${KV_API_PATH}"
fi

log "${KV_API_PATH}: written (gemini_api_key)"
log "done — 1 key written"
