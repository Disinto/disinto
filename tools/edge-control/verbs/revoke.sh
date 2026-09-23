#!/usr/bin/env bash
# =============================================================================
# verbs/revoke.sh — revoke a bound name (admin only)
#
#     revoke <name>
#
# The admin undo of a bound name (claim: register-request.sh, approve:
# verbs/approve.sh). The dispatcher (dispatch.sh) exports DISPATCH_FP before
# exec'ing this verb, so the caller is the admin account and <name> is the
# name to unbind. The row is NOT deleted — only its status is moved to
# revoked, so the name is freed while the account keeps its history and the
# unbinding stays auditable.
#
# Flow: validate arg -> require DISPATCH_FP -> admin gate (nothing written) ->
#       locate the row holding <name> ("unknown name" otherwise) -> apply the
#       side effects (lib/apply-name.sh: free the port, drop the route, rebuild
#       authorized_keys) -> only after a successful apply, set status to
#       revoked -> print the updated row. Any status can be revoked; re
#       revoking an already-revoked name is idempotent.
#
# Output contract (JSON on stdout unless noted):
#   rc 0  -> the updated compact account row of the name holder.
#   rc 1  -> {"error":"..."}:
#       "bad arguments"       — not exactly one argument
#       "missing fingerprint" — DISPATCH_FP unset [stderr]
#       "not admin"           — caller's row is not admin (nothing written)
#       "unknown name"        — no row holds <name> (nothing written)
#       "apply failed"        — the side effects (lib/apply-name.sh) failed
# Every failure path returns before the holder's row is ever rewritten.
# Revocation frees the route and port but keeps the ledger row intact.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/name-verbs.sh"
name_verb_preamble "$@"
if ! apply_revoke "$NAME" "$ADMIN_FP"; then
  fail_error "apply failed"
fi
account_set_status "$HOLDER" "revoked"
account_row "$HOLDER"
exit 0
