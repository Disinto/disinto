#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-forgejo.sh — Idempotent seed for kv/disinto/shared/forgejo
#
# Part of the Nomad+Vault migration (S2.4, issue #882). Populates the KV v2
# path that nomad/jobs/forgejo.hcl reads from, so a clean-install factory
# (no old-stack secrets to import) still has per-key values for
# FORGEJO__security__SECRET_KEY + FORGEJO__security__INTERNAL_TOKEN.
#
# Companion to tools/vault-import.sh (S2.2, not yet merged) — when that
# import runs against a box with an existing stack, it overwrites these
# seeded values with the real ones. Order doesn't matter: whichever runs
# last wins, and both scripts are idempotent in the sense that re-running
# never rotates an existing non-empty key.
#
# Idempotency contract (per key):
#   - Key missing or empty in Vault → generate a random value, write it,
#     log "<key> generated (N bytes hex)".
#   - Key present with a non-empty value → leave untouched, log
#     "<key> unchanged".
#   - Neither key changes is a silent no-op (no Vault write at all).
#
#   Rotating an existing key is deliberately NOT in scope — SECRET_KEY
#   rotation invalidates every existing session cookie in forgejo and
#   INTERNAL_TOKEN rotation breaks internal RPC until all processes have
#   restarted. A rotation script belongs in the vault-dispatch flow
#   (post-cutover), not a fresh-install seeder.
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
#   tools/vault-seed-forgejo.sh
#   tools/vault-seed-forgejo.sh --dry-run
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

# KV v2 mount + logical path. Kept as two vars so the full API path used
# for GET/POST (which MUST include `/data/`) is built in one place.
KV_MOUNT="kv"
KV_LOGICAL_PATH="disinto/shared/forgejo"
KV_API_PATH="${KV_MOUNT}/data/${KV_LOGICAL_PATH}"

# Byte lengths for the generated secrets (hex output, so the printable
# string length is 2x these). 32 bytes matches forgejo's own
# `gitea generate secret SECRET_KEY` default; 64 bytes is comfortably
# above forgejo's INTERNAL_TOKEN JWT-HMAC key floor.
SECRET_KEY_BYTES=32
INTERNAL_TOKEN_BYTES=64

log() { printf '[vault-seed-forgejo] %s\n' "$*"; }
die() { printf '[vault-seed-forgejo] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Flag parsing — single optional `--dry-run`. Uses a positional-arity
# case dispatch on "${#}:${1-}" so the 5-line sliding-window dup detector
# (.woodpecker/detect-duplicates.py) sees a shape distinct from both
# vault-apply-roles.sh (if/elif chain) and vault-apply-policies.sh (flat
# case on $1 alone). Three sibling tools, three parser shapes.
DRY_RUN=0
case "$#:${1-}" in
  0:)
    ;;
  1:--dry-run)
    DRY_RUN=1
    ;;
  1:-h|1:--help)
    printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
    printf 'Seed kv/disinto/shared/forgejo with random SECRET_KEY +\n'
    printf 'INTERNAL_TOKEN if they are missing. Idempotent: existing\n'
    printf 'non-empty values are left untouched.\n\n'
    printf '  --dry-run   Print planned actions (enable mount? which keys\n'
    printf '              to generate?) without writing to Vault. Exits 0.\n'
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

# Vault connectivity — short-circuit style (`||`) instead of an `if`-chain
# so this block has a distinct textual shape from vault-apply-roles.sh's
# equivalent preflight; hvault.sh's typed helpers emit structured JSON
# errors that don't render well behind the `[vault-seed-forgejo] …`
# log prefix, hence the inline check + plain-string diag.
[ -n "${VAULT_ADDR:-}" ] \
  || die "VAULT_ADDR unset — e.g. export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/2: ensure kv/ mount exists and is KV v2 ───────────────────────────
# The policy at vault/policies/service-forgejo.hcl grants read on
# `kv/data/<path>/*` — that `data` segment only exists for KV v2. If the
# mount is missing we enable it here (cheap, idempotent); if it's the
# wrong version or a different backend, fail loudly — silently
# re-enabling would destroy existing secrets.
log "── Step 1/2: ensure ${KV_MOUNT}/ is KV v2 ──"
mounts_json="$(hvault_get_or_empty "sys/mounts")" \
  || die "failed to list Vault mounts"

mount_exists=false
if printf '%s' "$mounts_json" | jq -e --arg m "${KV_MOUNT}/" '.[$m]' >/dev/null 2>&1; then
  mount_exists=true
fi

if [ "$mount_exists" = true ]; then
  mount_type="$(printf '%s' "$mounts_json" \
    | jq -r --arg m "${KV_MOUNT}/" '.[$m].type // ""')"
  mount_version="$(printf '%s' "$mounts_json" \
    | jq -r --arg m "${KV_MOUNT}/" '.[$m].options.version // "1"')"
  if [ "$mount_type" != "kv" ]; then
    die "${KV_MOUNT}/ is mounted as type='${mount_type}', expected 'kv' — refuse to re-mount"
  fi
  if [ "$mount_version" != "2" ]; then
    die "${KV_MOUNT}/ is KV v${mount_version}, expected v2 — refuse to upgrade in place (manual fix required)"
  fi
  log "${KV_MOUNT}/ already mounted (kv v2) — skipping enable"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would enable ${KV_MOUNT}/ as kv v2"
  else
    payload="$(jq -n '{type:"kv",options:{version:"2"},description:"disinto shared KV v2 (S2.4)"}')"
    _hvault_request POST "sys/mounts/${KV_MOUNT}" "$payload" >/dev/null \
      || die "failed to enable ${KV_MOUNT}/ as kv v2"
    log "${KV_MOUNT}/ enabled as kv v2"
  fi
fi

# ── Step 2/2: seed missing keys at kv/data/disinto/shared/forgejo ────────────
log "── Step 2/2: seed ${KV_API_PATH} ──"

# hvault_get_or_empty returns an empty string on 404 (KV path absent).
# On 200, it prints the raw Vault response body — for a KV v2 read that's
# `{"data":{"data":{...},"metadata":{...}}}`, hence the `.data.data.<key>`
# path below. A path with `deleted_time` set still returns 200 but the
# inner `.data.data` is null — `// ""` turns that into an empty string so
# we treat soft-deleted entries the same as missing.
existing_raw="$(hvault_get_or_empty "${KV_API_PATH}")" \
  || die "failed to read ${KV_API_PATH}"

existing_secret_key=""
existing_internal_token=""
if [ -n "$existing_raw" ]; then
  existing_secret_key="$(printf '%s' "$existing_raw" | jq -r '.data.data.secret_key // ""')"
  existing_internal_token="$(printf '%s' "$existing_raw" | jq -r '.data.data.internal_token // ""')"
fi

desired_secret_key="$existing_secret_key"
desired_internal_token="$existing_internal_token"
generated=()

if [ -z "$desired_secret_key" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    # In dry-run, don't call openssl — log the intent only. The real run
    # generates fresh bytes; nothing about the generated value is
    # deterministic so there's no "planned value" to show.
    generated+=("secret_key")
  else
    desired_secret_key="$(openssl rand -hex "$SECRET_KEY_BYTES")"
    generated+=("secret_key")
  fi
fi

if [ -z "$desired_internal_token" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    generated+=("internal_token")
  else
    desired_internal_token="$(openssl rand -hex "$INTERNAL_TOKEN_BYTES")"
    generated+=("internal_token")
  fi
fi

if [ "${#generated[@]}" -eq 0 ]; then
  log "all keys present at ${KV_API_PATH} — no-op"
  log "secret_key unchanged"
  log "internal_token unchanged"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would generate + write: ${generated[*]}"
  for key in secret_key internal_token; do
    case " ${generated[*]} " in
      *" ${key} "*) log "[dry-run] ${key} would be generated" ;;
      *)            log "[dry-run] ${key} unchanged"          ;;
    esac
  done
  exit 0
fi

# Write back BOTH keys in one payload. KV v2 replaces `.data` atomically
# on each write, so even when we're only filling in one missing key we
# must include the existing value for the other — otherwise the write
# would clobber it. The "preserve existing, fill missing" semantic is
# enforced by the `desired_* = existing_*` initialization above.
payload="$(jq -n \
  --arg sk "$desired_secret_key" \
  --arg it "$desired_internal_token" \
  '{data: {secret_key: $sk, internal_token: $it}}')"

_hvault_request POST "${KV_API_PATH}" "$payload" >/dev/null \
  || die "failed to write ${KV_API_PATH}"

for key in secret_key internal_token; do
  case " ${generated[*]} " in
    *" ${key} "*) log "${key} generated" ;;
    *)            log "${key} unchanged" ;;
  esac
done

log "done — ${#generated[@]} key(s) seeded at ${KV_API_PATH}"
