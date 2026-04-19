#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-ops-repo.sh — Idempotent seed for kv/disinto/shared/ops-repo
#
# Part of the Nomad+Vault migration (S5.1, issue #1035). Populates the KV v2
# path that nomad/jobs/edge.hcl dispatcher task reads from, so the edge
# proxy has FORGE_TOKEN for ops repo access.
#
# Seeds from kv/disinto/bots/vault (the vault bot credentials) — copies the
# token field to kv/disinto/shared/ops-repo. This is the "service" path that
# dispatcher uses, distinct from the "agent" path (bots/vault) used by
# agent tasks under the service-agents policy.
#
# Idempotency contract:
#   - Key present with non-empty value → leave untouched, log "token unchanged".
#   - Key missing or empty → copy from bots/vault, log "token copied".
#   - If bots/vault is also empty → generate a random value, log "token generated".
#
# Preconditions:
#   - Vault reachable + unsealed at $VAULT_ADDR.
#   - VAULT_TOKEN set (env) or /etc/vault.d/root.token readable.
#   - The `kv/` mount is enabled as KV v2.
#
# Requires:
#   - VAULT_ADDR  (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN (env OR /etc/vault.d/root.token, resolved by lib/hvault.sh)
#   - curl, jq, openssl
#
# Usage:
#   tools/vault-seed-ops-repo.sh
#   tools/vault-seed-ops-repo.sh --dry-run
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

# KV v2 mount + logical paths
KV_MOUNT="kv"
OPS_REPO_PATH="disinto/shared/ops-repo"
VAULT_BOT_PATH="disinto/bots/vault"

OPS_REPO_API="${KV_MOUNT}/data/${OPS_REPO_PATH}"
VAULT_BOT_API="${KV_MOUNT}/data/${VAULT_BOT_PATH}"

log() { printf '[vault-seed-ops-repo] %s\n' "$*"; }
die() { printf '[vault-seed-ops-repo] ERROR: %s\n' "$*" >&2; exit 1; }

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
    printf 'Seed kv/disinto/shared/ops-repo with FORGE_TOKEN.\n\n'
    printf 'Copies token from kv/disinto/bots/vault if present;\n'
    printf 'otherwise generates a random value. Idempotent:\n'
    printf 'existing non-empty values are left untouched.\n\n'
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

[ -n "${VAULT_ADDR:-}" ] \
  || die "VAULT_ADDR unset — e.g. export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/2: ensure kv/ mount exists and is KV v2 ───────────────────────────
log "── Step 1/2: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "[vault-seed-ops-repo]" \
  || die "KV mount check failed"

# ── Step 2/2: seed ops-repo from vault bot ───────────────────────────────────
log "── Step 2/2: seed ${OPS_REPO_API} ──"

# Read existing ops-repo value
existing_raw="$(hvault_get_or_empty "${OPS_REPO_API}")" \
  || die "failed to read ${OPS_REPO_API}"

existing_token=""
if [ -n "$existing_raw" ]; then
  existing_token="$(printf '%s' "$existing_raw" | jq -r '.data.data.token // ""')"
fi

desired_token="$existing_token"
action=""

if [ -z "$existing_token" ]; then
  # Token missing — try to copy from vault bot
  bot_raw="$(hvault_get_or_empty "${VAULT_BOT_API}")" || true
  if [ -n "$bot_raw" ]; then
    bot_token="$(printf '%s' "$bot_raw" | jq -r '.data.data.token // ""')"
    if [ -n "$bot_token" ]; then
      desired_token="$bot_token"
      action="copied"
    fi
  fi

  # If still no token, generate one
  if [ -z "$desired_token" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      action="generated (dry-run)"
    else
      desired_token="$(openssl rand -hex 32)"
      action="generated"
    fi
  fi
fi

if [ -z "$action" ]; then
  log "all keys present at ${OPS_REPO_API} — no-op"
  log "token unchanged"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] ${OPS_REPO_PATH}: would ${action} token"
  exit 0
fi

# Write the token
payload="$(jq -n --arg t "$desired_token" '{data: {token: $t}}')"
_hvault_request POST "${OPS_REPO_API}" "$payload" >/dev/null \
  || die "failed to write ${OPS_REPO_API}"

log "${OPS_REPO_PATH}: ${action} token"
log "done — ${OPS_REPO_API} seeded"
