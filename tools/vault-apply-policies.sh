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
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--dry-run]

Apply every vault/policies/*.hcl to Vault as an ACL policy. Idempotent:
unchanged policies are reported as "unchanged" and not written.

  --dry-run   Print policy names + content SHA256 that would be applied,
              without contacting Vault. Exits 0.
EOF
      exit 0
      ;;
    *) die "unknown flag: $1" ;;
  esac
done

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

# ── Helper: fetch the on-server policy text, or empty if absent ──────────────
# Echoes the current policy content on stdout. A 404 (policy does not exist
# yet) is a non-error — we print nothing and exit 0 so the caller can treat
# the empty string as "needs create". Any other non-2xx is a hard failure.
#
# Uses a subshell + EXIT trap (not RETURN) for tmpfile cleanup: the RETURN
# trap does NOT fire on set-e abort, so if jq below tripped errexit the
# tmpfile would leak. Subshell exit propagates via the function's last-
# command exit status.
fetch_current_policy() {
  local name="$1"
  (
    local tmp http_code
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    http_code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      "${VAULT_ADDR}/v1/sys/policies/acl/${name}")" \
      || { printf '[vault-apply] ERROR: curl failed for policy %s\n' "$name" >&2; exit 1; }
    case "$http_code" in
      200) jq -r '.data.policy // ""' < "$tmp" ;;
      404) printf '' ;;  # absent — caller treats as "create"
      *)
        printf '[vault-apply] ERROR: HTTP %s fetching policy %s:\n' "$http_code" "$name" >&2
        cat "$tmp" >&2
        exit 1
        ;;
    esac
  )
}

# ── Apply each policy, reporting created/updated/unchanged ───────────────────
log "syncing ${#POLICY_FILES[@]} polic(y|ies) from ${POLICIES_DIR}"

for f in "${POLICY_FILES[@]}"; do
  name="$(basename "$f" .hcl)"

  desired="$(cat "$f")"
  current="$(fetch_current_policy "$name")" \
    || die "failed to read existing policy: ${name}"

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
