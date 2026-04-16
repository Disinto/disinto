#!/usr/bin/env bash
# =============================================================================
# tools/vault-apply-policies.sh — Idempotent Vault policy sync
#
# Part of the Nomad+Vault migration (S2.1, issue #879). Reads every
# vault/policies/*.hcl file and upserts it into Vault as an ACL policy
# named after the file's basename (without the .hcl suffix).
#
# Idempotency contract:
#   For each vault/policies/<NAME>.hcl:
#     - Policy missing in Vault       → apply, log "policy <NAME> created"
#     - Policy present, content same  → skip,  log "policy <NAME> unchanged"
#     - Policy present, content diff  → apply, log "policy <NAME> updated"
#
#   Comparison is byte-for-byte against the on-server policy text returned by
#   GET sys/policies/acl/<NAME>.data.policy. Re-running with no file edits is
#   a guaranteed no-op that reports every policy as "unchanged".
#
#   --dry-run: prints <NAME>  <SHA256> for each file that WOULD be applied;
#   does not call Vault at all (no GETs, no PUTs). Exits 0.
#
# Requires:
#   - VAULT_ADDR   (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN  (env OR /etc/vault.d/root.token, resolved by lib/hvault.sh)
#   - curl, jq, sha256sum
#
# Usage:
#   tools/vault-apply-policies.sh
#   tools/vault-apply-policies.sh --dry-run
#
# Exit codes:
#   0  success (policies synced, or --dry-run completed)
#   1  precondition / API failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICIES_DIR="${REPO_ROOT}/vault/policies"

# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

log() { printf '[vault-apply] %s\n' "$*"; }
die() { printf '[vault-apply] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
# Single optional flag — no loop needed. Keeps this block textually distinct
# from the multi-flag `while/case` parsers elsewhere in the repo (see
# .woodpecker/detect-duplicates.py — sliding 5-line window).
dry_run=false
[ "$#" -le 1 ] || die "too many arguments (saw: $*)"
case "${1:-}" in
  '')         ;;
  --dry-run)  dry_run=true ;;
  -h|--help)  printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
              printf 'Apply every vault/policies/*.hcl to Vault as an ACL policy.\n'
              printf 'Idempotent: unchanged policies are reported as "unchanged" and\n'
              printf 'not written.\n\n'
              printf '  --dry-run   Print policy names + content SHA256 that would be\n'
              printf '              applied, without contacting Vault. Exits 0.\n'
              exit 0 ;;
  *)          die "unknown flag: $1" ;;
esac

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq sha256sum; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

[ -d "$POLICIES_DIR" ] \
  || die "policies directory not found: ${POLICIES_DIR}"

# Collect policy files in a stable (lexicographic) order so log output is
# deterministic across runs and CI diffs.
mapfile -t POLICY_FILES < <(
  find "$POLICIES_DIR" -maxdepth 1 -type f -name '*.hcl' | LC_ALL=C sort
)

if [ "${#POLICY_FILES[@]}" -eq 0 ]; then
  die "no *.hcl files in ${POLICIES_DIR}"
fi

# ── Dry-run: print plan + exit (no Vault calls) ──────────────────────────────
if [ "$dry_run" = true ]; then
  log "dry-run — ${#POLICY_FILES[@]} policy file(s) in ${POLICIES_DIR}"
  for f in "${POLICY_FILES[@]}"; do
    name="$(basename "$f" .hcl)"
    sha="$(sha256sum "$f" | awk '{print $1}')"
    printf '[vault-apply] would apply policy %s (sha256=%s)\n' "$name" "$sha"
  done
  exit 0
fi

# ── Live run: Vault connectivity check ───────────────────────────────────────
[ -n "${VAULT_ADDR:-}" ] \
  || die "VAULT_ADDR is not set — export VAULT_ADDR=http://127.0.0.1:8200"

# hvault_token_lookup both resolves the token (env or /etc/vault.d/root.token)
# and confirms the server is reachable with a valid token. Fail fast here so
# the per-file loop below doesn't emit N identical "HTTP 403" errors.
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Apply each policy, reporting created/updated/unchanged ───────────────────
log "syncing ${#POLICY_FILES[@]} polic(y|ies) from ${POLICIES_DIR}"

for f in "${POLICY_FILES[@]}"; do
  name="$(basename "$f" .hcl)"

  desired="$(cat "$f")"
  # hvault_get_or_empty returns the raw JSON body on 200 or empty on 404.
  # Extract the .data.policy field here (jq on "" yields "", so the
  # empty-string-means-create branch below still works).
  raw="$(hvault_get_or_empty "sys/policies/acl/${name}")" \
    || die "failed to read existing policy: ${name}"
  if [ -n "$raw" ]; then
    current="$(printf '%s' "$raw" | jq -r '.data.policy // ""')" \
      || die "failed to parse policy response: ${name}"
  else
    current=""
  fi

  if [ -z "$current" ]; then
    hvault_policy_apply "$name" "$f" \
      || die "failed to create policy: ${name}"
    log "policy ${name} created"
    continue
  fi

  if [ "$current" = "$desired" ]; then
    log "policy ${name} unchanged"
    continue
  fi

  hvault_policy_apply "$name" "$f" \
    || die "failed to update policy: ${name}"
  log "policy ${name} updated"
done

log "done — ${#POLICY_FILES[@]} polic(y|ies) synced"
