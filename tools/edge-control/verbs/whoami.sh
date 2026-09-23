#!/usr/bin/env bash
# =============================================================================
# verbs/whoami.sh — print this caller's account row.
#
# The dispatcher (dispatch.sh) identifies the caller via key fingerprint,
# account_ensure()'s their row, exports DISPATCH_FP, and execs this verb.
# whoami answers "who am I / what is my standing on the edge plane?" by
# printing the account row JSON for DISPATCH_FP as a single line.
#
# Any trailing arguments (e.g. from SSH_ORIGINAL_COMMAND) are accepted and
# ignored. Exits 0 on success.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared account ledger (fingerprint contract + row reader).
# shellcheck source=../lib/accounts.sh
source "${SCRIPT_DIR}/../lib/accounts.sh"

# dispatch.sh always exports DISPATCH_FP before exec'ing a verb; guard the
# invariant so an internal miswire is a visible failure, not a silent miss.
if [[ -z "${DISPATCH_FP:-}" ]]; then
  echo '{"error":"missing fingerprint"}' >&2
  exit 1
fi

account_row "$DISPATCH_FP"
exit 0
