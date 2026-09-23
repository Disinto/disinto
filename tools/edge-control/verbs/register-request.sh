#!/usr/bin/env bash
# =============================================================================
# verbs/register-request.sh — claim a project name for this fingerprint
#
# The "doorman" of the name claim. The dispatcher (dispatch.sh) exports
# DISPATCH_FP before exec'ing this verb, and the caller requests exactly one
# project name:
#
#     register-request <project>
#
# A claim is *not* an allocation. This verb binds the `name` field of the
# caller's ledger row (lib/accounts.sh) and leaves status at `pending`.
# Port allocation, Caddy route changes, and authorized_keys changes belong to
# the admin approve verb (#1466); nothing here loads lib/ports.sh,
# lib/caddy.sh, or lib/authorized_keys.sh.
#
# Output contract (JSON on stdout, one line; exit code):
#   rc 0  -> the caller's compact account row (name bound, status pending).
#            Re-requesting a name this fingerprint already holds is idempotent:
#            the same row is printed, nothing else written.
#   rc 1  -> {"error":"..."} with one of:
#       "bad arguments"        — not exactly one argument
#       "missing fingerprint"  — internal miswire (DISPATCH_FP unset) [stderr]
#       "invalid project name" — fails ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$
#       "name reserved"        — in RESERVED_NAMES
#       "name taken"           — another fingerprint's row holds the name
#       "already named"        — this fingerprint holds a different name
#   Every failure path returns before touching the ledger.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ledger + fingerprint contract (shared with dispatch.sh and the other verbs).
source "${SCRIPT_DIR}/../lib/accounts.sh"

# Operator-adjacent and internal-role names; no project may claim one of these.
RESERVED_NAMES=(www api admin root mail chat forge ci edge caddy disinto register tunnel)

# JSON error on stdout; non-zero exit.
fail_error() {
  printf '{"error":"%s"}\n' "$1"
  exit 1
}

[[ $# -eq 1 ]] \
  || fail_error "bad arguments"
project="$1"

# The dispatcher always exports DISPATCH_FP before exec'ing a verb.
fp="${DISPATCH_FP:-}"
[[ -n "$fp" ]] \
  || { printf '{"error":"missing fingerprint"}\n' >&2; exit 1; }

# 1) shape: strict DNS-label name (3-63 chars, register.sh's contract).
if [[ ! "$project" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  fail_error "invalid project name"
fi

# 2) reserved names, before any ledger lookup.
for reserved in "${RESERVED_NAMES[@]}"; do
  if [[ "$project" == "$reserved" ]]; then
    fail_error "name reserved"
  fi
done

# 3) this fingerprint's own binding, if any.
account_ensure "$fp"
my_name=$(jq -r --arg fp "$fp" '(.accounts // {})[$fp].name // empty' "$ACCOUNTS_FILE")
if [[ -n "$my_name" ]]; then
  if [[ "$my_name" == "$project" ]]; then
    # Idempotent: caller re-requests the name it already holds.
    print_account_row
  else
    fail_error "already named"
  fi
fi

# 4) does some *other* fingerprint already hold the name?
taken_by=$(jq -r --arg fp "$fp" --arg n "$project" '
  [ (.accounts // {}) | to_entries[]
    | select((.key != $fp) and ((.value.name // empty) == $n))
    | .key ]
  | .[0] // empty' "$ACCOUNTS_FILE")
if [[ -n "$taken_by" ]]; then
  fail_error "name taken"
fi

# 5) claim: bind the name, leave status pending. Then report the row.
account_set_name "$fp" "$project"
print_account_row
