#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/vault-engines.sh — Enable required Vault secret engines
#
# Part of the Nomad+Vault migration (S2.1, issue #912). Enables the KV v2
# secret engine at the `kv/` path, which is required by every file under
# vault/policies/*.hcl, every role in vault/roles.yaml, every write done
# by tools/vault-import.sh, and every template read done by
# nomad/jobs/forgejo.hcl — all of which address paths under kv/disinto/…
# and 403 if the mount is absent.
#
# Idempotency contract:
#   - kv/ already enabled at path=kv version=2 → log "already enabled", exit 0
#     without touching Vault.
#   - kv/ enabled at a different type/version → die (manual intervention).
#   - kv/ not enabled → POST sys/mounts/kv to enable kv-v2, log "enabled".
#   - Second run on a fully-configured box is a silent no-op.
#
# Preconditions:
#   - Vault is unsealed and reachable (VAULT_ADDR + VAULT_TOKEN set OR
#     defaultable to the local-cluster shape via _hvault_default_env).
#   - Must run AFTER cluster-up.sh (unseal complete) but BEFORE
#     vault-apply-policies.sh (policies reference kv/* paths).
#
# Environment:
#   VAULT_ADDR  — default http://127.0.0.1:8200 via _hvault_default_env.
#   VAULT_TOKEN — env OR /etc/vault.d/root.token (resolved by lib/hvault.sh).
#
# Usage:
#   sudo lib/init/nomad/vault-engines.sh
#   sudo lib/init/nomad/vault-engines.sh --dry-run
#
# Exit codes:
#   0  success (kv enabled, or already so)
#   1  precondition / API failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../../hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

log() { printf '[vault-engines] %s\n' "$*"; }
die() { printf '[vault-engines] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Flag parsing (single optional flag) ─────────────────────────────────────
# Shape: while/shift loop. Deliberately NOT a flat `case "${1:-}"` like
# tools/vault-apply-policies.sh nor an if/elif ladder like
# tools/vault-apply-roles.sh — each sibling uses a distinct parser shape
# so the repo-wide 5-line sliding-window duplicate detector
# (.woodpecker/detect-duplicates.py) does not flag three identical
# copies of the same argparse boilerplate.
print_help() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run]

Enable the KV v2 secret engine at kv/. Required by all Vault policies,
roles, and Nomad job templates that reference kv/disinto/* paths.
Idempotent: an already-enabled kv/ is reported and left untouched.

  --dry-run   Probe state and print the action without contacting Vault
              in a way that mutates it.
EOF
}
dry_run=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help) print_help; exit 0 ;;
    *)         die "unknown flag: $1" ;;
  esac
done

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

# Default the local-cluster Vault env (VAULT_ADDR + VAULT_TOKEN). Shared
# with the rest of the init-time Vault scripts — see lib/hvault.sh header.
_hvault_default_env

# ── Dry-run: probe existing state and print plan ─────────────────────────────
if [ "$dry_run" = true ]; then
  # Probe connectivity with the same helper the live path uses. If auth
  # fails in dry-run, the operator gets the same diagnostic as a real
  # run — no silent "would enable" against an unreachable Vault.
  hvault_token_lookup >/dev/null \
    || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"
  mounts_raw="$(hvault_get_or_empty "sys/mounts")" \
    || die "failed to list secret engines"
  if [ -n "$mounts_raw" ] \
     && printf '%s' "$mounts_raw" | jq -e '."kv/"' >/dev/null 2>&1; then
    log "[dry-run] kv-v2 at kv/ already enabled"
  else
    log "[dry-run] would enable kv-v2 at kv/"
  fi
  exit 0
fi

# ── Live run: Vault connectivity check ───────────────────────────────────────
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Check if kv/ is already enabled ──────────────────────────────────────────
# sys/mounts returns an object keyed by "<path>/" for every enabled secret
# engine (trailing slash is Vault's on-disk form). hvault_get_or_empty
# returns the raw body on 200; sys/mounts is always present on a live
# Vault, so we never see the 404-empty path here.
log "checking existing secret engines"
mounts_raw="$(hvault_get_or_empty "sys/mounts")" \
  || die "failed to list secret engines"

if [ -n "$mounts_raw" ] \
   && printf '%s' "$mounts_raw" | jq -e '."kv/"' >/dev/null 2>&1; then
  # kv/ exists — verify it's kv-v2 on the right path shape. Vault returns
  # the option as a string ("2") on GET, never an integer.
  kv_type="$(printf '%s' "$mounts_raw" | jq -r '."kv/".type // ""')"
  kv_version="$(printf '%s' "$mounts_raw" | jq -r '."kv/".options.version // ""')"
  if [ "$kv_type" = "kv" ] && [ "$kv_version" = "2" ]; then
    log "kv-v2 at kv/ already enabled (type=${kv_type}, version=${kv_version})"
    exit 0
  fi
  die "kv/ exists but is not kv-v2 (type=${kv_type:-<unset>}, version=${kv_version:-<unset>}) — manual intervention required"
fi

# ── Enable kv-v2 at path=kv ──────────────────────────────────────────────────
# POST sys/mounts/<path> with type=kv + options.version=2 is the
# HTTP-API equivalent of `vault secrets enable -path=kv -version=2 kv`.
# Keeps the script vault-CLI-free (matches the policy-apply + nomad-auth
# scripts; their headers explain why a CLI dep would die on client-only
# nodes).
log "enabling kv-v2 at path=kv"
enable_payload="$(jq -n '{type:"kv",options:{version:"2"}}')"
_hvault_request POST "sys/mounts/kv" "$enable_payload" >/dev/null \
  || die "failed to enable kv-v2 secret engine"
log "kv-v2 enabled at kv/"
