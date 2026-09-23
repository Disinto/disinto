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
#   Every failure path returns before the holder's status is ever changed.
# Approval is the only name verb that may allocate a port or add a route.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/name-verbs.sh"
name_verb_preamble "$@"
status="$(jq -r --arg fp "$HOLDER" '(.accounts // {})[$fp].status // empty' "$ACCOUNTS_FILE")"
if [[ "$status" != "pending" && "$status" != "approved" ]]; then
  fail_error "not approvable"
fi
if ! apply_approve "$NAME" "$ADMIN_FP"; then
  fail_error "apply failed"
fi
account_set_status "$HOLDER" "approved"
account_row "$HOLDER"
exit 0
