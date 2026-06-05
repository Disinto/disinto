#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-agents.sh — Idempotent seed for all bot KV paths
#
# Part of the Nomad+Vault migration (S4.1, issue #955). Populates
# kv/disinto/bots/<role> with token + pass for each of the 7 agent roles
# plus the vault bot. Handles the "fresh factory, no .env import" case.
#
# Companion to tools/vault-import.sh — when that runs against a box with
# an existing stack, it overwrites seeded values with real ones.
#
# Idempotency contract (per bot):
#   - Both token and pass present → skip, log "<role> unchanged".
#   - Either missing → generate random values for missing keys, preserve
#     existing keys, write back atomically.
#
# Preconditions:
#   - Vault reachable + unsealed at $VAULT_ADDR.
#   - VAULT_TOKEN set (env) or /etc/vault.d/root.token readable.
#   - curl, jq, openssl
#
# Usage:
#   tools/vault-seed-agents.sh
#   tools/vault-seed-agents.sh --dry-run
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
TOKEN_BYTES=32   # 32 bytes → 64 hex chars
PASS_BYTES=16    # 16 bytes → 32 hex chars

# All bot roles seeded by this script.
BOT_ROLES=(dev review gardener architect planner predictor supervisor vault)

LOG_TAG="[vault-seed-agents]"
log() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
# while/shift shape — distinct from forgejo (arity:value case) and
# woodpecker (for-loop).
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
      printf 'Seed kv/disinto/bots/<role> with token + pass for all agent\n'
      printf 'roles. Idempotent: existing non-empty values are preserved.\n\n'
      printf '  --dry-run   Print planned actions without writing.\n'
      exit 0
      ;;
    *) die "invalid argument: ${1}  (try --help)" ;;
  esac
  shift
done

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done
[ -n "${VAULT_ADDR:-}" ] \
  || die "VAULT_ADDR unset — e.g. export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1: ensure kv/ mount exists and is KV v2 ────────────────────────────
log "── Step 1: ensure ${KV_MOUNT}/ is KV v2 ──"
export DRY_RUN
hvault_ensure_kv_v2 "$KV_MOUNT" "${LOG_TAG}" \
  || die "KV mount check failed"

# ── Step 2: seed each bot role ───────────────────────────────────────────────
total_generated=0

# Check if shared forge credentials exist for dev role fallback
shared_forge_exists=0
shared_forge_raw="$(hvault_get_or_empty "${KV_MOUNT}/data/disinto/shared/forge")" \
  || true
if [ -n "$shared_forge_raw" ]; then
  shared_forge_token="$(printf '%s' "$shared_forge_raw" | jq -r '.data.data.token // ""')"
  shared_forge_pass="$(printf '%s' "$shared_forge_raw" | jq -r '.data.data.pass // ""')"
  if [ -n "$shared_forge_token" ] && [ -n "$shared_forge_pass" ]; then
    shared_forge_exists=1
  fi
fi

for role in "${BOT_ROLES[@]}"; do
  kv_logical="disinto/bots/${role}"
  kv_api="${KV_MOUNT}/data/${kv_logical}"

  log "── seed ${kv_logical} ──"

  existing_raw="$(hvault_get_or_empty "${kv_api}")" \
    || die "failed to read ${kv_api}"

  existing_token=""
  existing_pass=""
  existing_data="{}"
  if [ -n "$existing_raw" ]; then
    existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"
    existing_token="$(printf '%s' "$existing_raw" | jq -r '.data.data.token // ""')"
    existing_pass="$(printf '%s' "$existing_raw" | jq -r '.data.data.pass // ""')"
  fi

  generated=()
  desired_token="$existing_token"
  desired_pass="$existing_pass"

  # Special case: dev role uses shared forge credentials if available
  if [ "$role" = "dev" ] && [ "$shared_forge_exists" -eq 1 ]; then
    # Use shared FORGE_TOKEN + FORGE_PASS for dev role
    if [ -z "$existing_token" ]; then
      desired_token="$shared_forge_token"
      generated+=("token")
    fi
    if [ -z "$existing_pass" ]; then
      desired_pass="$shared_forge_pass"
      generated+=("pass")
    fi
  else
    # Generate random values for missing keys
    if [ -z "$existing_token" ]; then
      generated+=("token")
    fi
    if [ -z "$existing_pass" ]; then
      generated+=("pass")
    fi

    for key in "${generated[@]}"; do
      case "$key" in
        token) desired_token="$(openssl rand -hex "$TOKEN_BYTES")" ;;
        pass)  desired_pass="$(openssl rand -hex "$PASS_BYTES")" ;;
      esac
    done
  fi

  if [ "${#generated[@]}" -eq 0 ]; then
    log "${role}: unchanged"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ${role}: would generate ${generated[*]}"
    total_generated=$(( total_generated + ${#generated[@]} ))
    continue
  fi

  # Merge new keys into existing data to preserve any keys we don't own.
  payload="$(printf '%s' "$existing_data" \
    | jq --arg t "$desired_token" --arg p "$desired_pass" \
      '{data: (. + {token: $t, pass: $p})}')"

  _hvault_request POST "${kv_api}" "$payload" >/dev/null \
    || die "failed to write ${kv_api}"

  log "${role}: generated ${generated[*]}"
  total_generated=$(( total_generated + ${#generated[@]} ))
done

if [ "$total_generated" -eq 0 ]; then
  log "all bot paths already seeded — no-op"
else
  log "done — ${total_generated} key(s) seeded across ${#BOT_ROLES[@]} bot paths"
fi
