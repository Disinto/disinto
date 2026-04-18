#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-chat.sh — Idempotent seed for kv/disinto/shared/chat
#
# Part of the Nomad+Vault migration (S5.2, issue #989). Populates the KV v2
# path that nomad/jobs/chat.hcl reads from, so a clean-install factory
# (no old-stack secrets to import) still has per-key values for
# CHAT_OAUTH_CLIENT_ID, CHAT_OAUTH_CLIENT_SECRET, and FORWARD_AUTH_SECRET.
#
# Companion to tools/vault-import.sh (S2.2) — when that import runs against
# a box with an existing stack, it overwrites these seeded values with the
# real ones. Order doesn't matter: whichever runs last wins, and both
# scripts are idempotent in the sense that re-running never rotates an
# existing non-empty key.
#
# Uses _hvault_seed_key (lib/hvault.sh) for each key — the helper reads
# existing data and merges to preserve sibling keys (KV v2 replaces .data
# atomically).
#
# Preconditions:
#   - Vault reachable + unsealed at $VAULT_ADDR.
#   - VAULT_TOKEN set (env) or /etc/vault.d/root.token readable.
#   - The `kv/` mount is enabled as KV v2.
#
# Requires: VAULT_ADDR, VAULT_TOKEN, curl, jq, openssl
#
# Usage:
#   tools/vault-seed-chat.sh
#   tools/vault-seed-chat.sh --dry-run
#
# Exit codes:
#   0  success (seed applied, or already applied)
#   1  precondition / API / mount-mismatch failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

KV_MOUNT="kv"
KV_LOGICAL_PATH="disinto/shared/chat"

# Keys to seed — array-driven loop (structurally distinct from forgejo's
# sequential if-blocks and agents' role loop).
SEED_KEYS=(chat_oauth_client_id chat_oauth_client_secret forward_auth_secret)

LOG_TAG="[vault-seed-chat]"
log() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# ── Flag parsing — [[ ]] guard + case: shape distinct from forgejo
# (arity:value case), woodpecker (for-loop), agents (while/shift).
DRY_RUN=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
      printf 'Seed kv/disinto/shared/chat with random OAuth client\n'
      printf 'credentials and forward auth secret if missing.\n'
      printf 'Idempotent: existing non-empty values are preserved.\n\n'
      printf '  --dry-run   Print planned actions without writing.\n'
      exit 0
      ;;
    *) die "invalid argument: ${1}  (try --help)" ;;
  esac
fi

# ── Preconditions ────────────────────────────────────────────────────────────
required_bins=(curl jq openssl)
for bin in "${required_bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || die "required binary not found: ${bin}"
done
[ -n "${VAULT_ADDR:-}" ] || die "VAULT_ADDR unset — export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/2: ensure kv/ mount exists and is KV v2 ───────────────────────────
log "── Step 1/2: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "${LOG_TAG}" \
  || die "KV mount check failed"

# ── Step 2/2: seed missing keys via _hvault_seed_key helper ──────────────────
log "── Step 2/2: seed ${KV_LOGICAL_PATH} ──"

generated=()
for key in "${SEED_KEYS[@]}"; do
  if [ "$DRY_RUN" -eq 1 ]; then
    # Check existence without writing
    existing=$(hvault_kv_get "$KV_LOGICAL_PATH" "$key" 2>/dev/null) || true
    if [ -z "$existing" ]; then
      generated+=("$key")
      log "[dry-run] ${key} would be generated"
    else
      log "[dry-run] ${key} unchanged"
    fi
  else
    if _hvault_seed_key "$KV_LOGICAL_PATH" "$key"; then
      generated+=("$key")
      log "${key} generated"
    else
      log "${key} unchanged"
    fi
  fi
done

if [ "${#generated[@]}" -eq 0 ]; then
  log "all keys present — no-op"
else
  log "done — ${#generated[@]} key(s) seeded at kv/${KV_LOGICAL_PATH}"
fi
