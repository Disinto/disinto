#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-woodpecker.sh — Idempotent seed for kv/disinto/shared/woodpecker
#
# Part of the Nomad+Vault migration (S3.1, issue #934). Populates the
# `agent_secret` key at the KV v2 path that nomad/jobs/woodpecker-server.hcl
# reads from, so a clean-install factory has a pre-shared agent secret for
# woodpecker-server ↔ woodpecker-agent communication.
#
# Scope: ONLY seeds `agent_secret`. The Forgejo OAuth client/secret
# (`forgejo_client`, `forgejo_secret`) are written by S3.3's
# wp-oauth-register.sh after creating the OAuth app via the Forgejo API.
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
      printf 'Seed kv/disinto/shared/woodpecker with a random agent_secret\n'
      printf 'if it is missing. Idempotent: existing non-empty values are\n'
      printf 'left untouched.\n\n'
      printf '  --dry-run   Print planned actions without writing to Vault.\n'
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

# ── Step 1/2: ensure kv/ mount exists and is KV v2 ───────────────────────────
log "── Step 1/2: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "[vault-seed-woodpecker]" \
  || die "KV mount check failed"

# ── Step 2/2: seed agent_secret at kv/data/disinto/shared/woodpecker ─────────
log "── Step 2/2: seed ${KV_API_PATH} ──"

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
  exit 0
fi

# agent_secret is missing — generate it.
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would generate + write: agent_secret"
  exit 0
fi

new_agent_secret="$(openssl rand -hex "$AGENT_SECRET_BYTES")"

# Merge the new key into existing data to preserve any keys written by
# other seeders (e.g. S3.3's forgejo_client/forgejo_secret).
payload="$(printf '%s' "$existing_data" \
  | jq --arg as "$new_agent_secret" '{data: (. + {agent_secret: $as})}')"

_hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null \
  || die "failed to write ${KV_API_PATH}"

log "agent_secret generated"
log "done — 1 key seeded at ${KV_API_PATH}"
