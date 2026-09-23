#!/usr/bin/env bash
# =============================================================================
# verbs/approve.sh — approve a claimed name (admin only)
#
#     approve <name>
#
# The admin half of the name-claim workflow (claim: register-request.sh, this
# verb: the bind). The dispatcher (dispatch.sh) exports DISPATCH_FP before
# exec'ing this verb, so the *caller* is the account identified by DISPATCH_FP
# and <name> is the claimed subdomain to bind. Approval is the only mutation
# that may allocate a port.
#
# Flow: validate arg -> require DISPATCH_FP -> admin gate (fail closed,
#       nothing written) -> locate the row holding <name> ("unknown name"
#       otherwise) -> require its status in {pending, approved} -> apply the
#       network side effects (lib/apply-name.sh, EDGE_APPLY mode) -> only after
#       a successful apply, set status to approved -> print the updated row.
#       Re-approving an already-approved name is idempotent.
#
# Output contract (JSON on stdout unless noted):
#   rc 0  -> the updated compact account row of the name holder.
#   rc 1  -> {"error":"..."} with one of:
#       "bad arguments"        — not exactly one argument
#       "missing fingerprint"  — DISPATCH_FP unset [stderr]
#       "not admin"            — caller's row is not admin (nothing written)
#       "unknown name"         — no row holds <name> (nothing written)
#       "not approvable"       — the holder's status is not pending/approved
#       "apply failed"         — the side effects (lib/apply-name.sh) failed
#   Every failure path returns before the ledger status is changed.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"
source "${SCRIPT_DIR}/../lib/apply-name.sh"

fail_error() {
  printf '{"error":"%s"}\n' "$1"
  exit 1
}

[[ $# -eq 1 ]] \
  || fail_error "bad arguments"
name="$1"

# The caller (DISPATCH_FP), then the admin gate — before anything is written.
fp="$(require_dispatch_fp)" || exit 1
require_admin "$fp"

# The name's shape and reservedness were validated at claim time (register
# request); a malformed <name> simply matches no row below ("unknown name").
holder="$(row_fp_by_name "$name")"
if [[ -z "$holder" ]]; then
  fail_error "unknown name"
fi

status="$(jq -r --arg fp "$holder" \
  '(.accounts // {})[$fp].status // empty' "$ACCOUNTS_FILE")"
if [[ "$status" != "pending" && "$status" != "approved" ]]; then
  fail_error "not approvable"
fi

# Side effects first; only a successful apply (stub and 0 count as success)
# may leave the status changed.
if ! apply_approve "$name" "$fp"; then
  fail_error "apply failed"
fi

account_set_status "$holder" "approved"
account_row "$holder"
exit 0
