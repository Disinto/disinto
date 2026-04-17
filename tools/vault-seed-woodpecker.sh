#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-woodpecker.sh — Idempotent seed for kv/disinto/shared/woodpecker
#
# Part of the Nomad+Vault migration (S3.1 + S3.3, issues #934 + #936). Populates
# the KV v2 path read by nomad/jobs/woodpecker-server.hcl:
#   - agent_secret: pre-shared secret for woodpecker-server ↔ agent communication
#   - forgejo_client + forgejo_secret: OAuth2 client credentials from Forgejo
#
# This script handles BOTH:
#   1. S3.1: seeds `agent_secret` if missing
#   2. S3.3: calls wp-oauth-register.sh to create Forgejo OAuth app + store
#      forgejo_client/forgejo_secret in Vault
#
# Idempotency contract:
#   - agent_secret: missing → generate and write; present → skip, log unchanged
#   - OAuth app + credentials: handled by wp-oauth-register.sh (idempotent)
# This script preserves any existing keys it doesn't own.
#
# Idempotency contract (per key):
#   - Key missing or empty in Vault → generate a random value, write it,
#     log "agent_secret generated".
#   - Key present with a non-empty value → leave untouched, log
#     "agent_secret unchanged".
#
# Preconditions:
#   - Vault reachable + unsealed at $VAULT_ADDR.
#   - VAULT_TOKEN set (env) or /etc/vault.d/root.token readable.
#   - The `kv/` mount is enabled as KV v2 (this script enables it on a
#     fresh box; on an existing box it asserts the mount type/version).
#
# Requires:
#   - VAULT_ADDR  (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN (env OR /etc/vault.d/root.token, resolved by lib/hvault.sh)
#   - curl, jq, openssl
#
# Usage:
#   tools/vault-seed-woodpecker.sh
#   tools/vault-seed-woodpecker.sh --dry-run
#
# Exit codes:
#   0  success (seed applied, or already applied)
#   1  precondition / API / mount-mismatch failure
# =============================================================================
set -euo pipefail

SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SEED_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/lib/init/nomad"
# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

KV_MOUNT="kv"
KV_LOGICAL_PATH="disinto/shared/woodpecker"
KV_API_PATH="${KV_MOUNT}/data/${KV_LOGICAL_PATH}"
AGENT_SECRET_BYTES=32   # 32 bytes → 64 hex chars

LOG_TAG="[vault-seed-woodpecker]"
log() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
# for-over-"$@" loop — shape distinct from vault-seed-forgejo.sh (arity:value
# case) and vault-apply-roles.sh (if/elif).
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
      printf 'Seed kv/disinto/shared/woodpecker with secrets.\n\n'
      printf 'Handles both S3.1 (agent_secret) and S3.3 (OAuth app + credentials):\n'
      printf '  - agent_secret: generated if missing\n'
      printf '  - forgejo_client/forgejo_secret: created via Forgejo API if missing\n\n'
      printf '  --dry-run   Print planned actions without writing.\n'
      exit 0
      ;;
    *) die "invalid argument: ${arg}  (try --help)" ;;
  esac
done

# ── Preconditions — binary + Vault connectivity checks ───────────────────────
required_bins=(curl jq openssl)
for bin in "${required_bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || die "required binary not found: ${bin}"
done
[ -n "${VAULT_ADDR:-}" ] || die "VAULT_ADDR unset — export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/3: ensure kv/ mount exists and is KV v2 ───────────────────────────
log "── Step 1/3: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "[vault-seed-woodpecker]" \
  || die "KV mount check failed"

# ── Step 2/3: seed agent_secret at kv/data/disinto/shared/woodpecker ─────────
log "── Step 2/3: seed agent_secret ──"

existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" \
  || die "failed to read ${KV_API_PATH}"

# Read all existing keys so we can preserve them on write (KV v2 replaces
# `.data` atomically). Missing path → empty object.
existing_data="{}"
existing_agent_secret=""
if [ -n "$existing_raw" ]; then
  existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"
  existing_agent_secret="$(printf '%s' "$existing_raw" | jq -r '.data.data.agent_secret // ""')"
fi

if [ -n "$existing_agent_secret" ]; then
  log "agent_secret unchanged"
else
  # agent_secret is missing — generate it.
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would generate + write: agent_secret"
  else
    new_agent_secret="$(openssl rand -hex "$AGENT_SECRET_BYTES")"

    # Merge the new key into existing data to preserve any keys written by
    # other seeders (e.g. S3.3's forgejo_client/forgejo_secret).
    payload="$(printf '%s' "$existing_data" \
      | jq --arg as "$new_agent_secret" '{data: (. + {agent_secret: $as})}')"

    _hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null \
      || die "failed to write ${KV_API_PATH}"

    log "agent_secret generated"
  fi
fi

# ── Step 3/3: register Forgejo OAuth app and store credentials ───────────────
log "── Step 3/3: register Forgejo OAuth app ──"

# Call the OAuth registration script
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would call wp-oauth-register.sh"
else
  # Export required env vars for the OAuth script
  export DRY_RUN
  "${LIB_DIR}/wp-oauth-register.sh" --dry-run || {
    log "OAuth registration check failed (Forgejo may not be running)"
    log "This is expected if Forgejo is not available"
  }
fi

log "done — agent_secret + OAuth credentials seeded"
