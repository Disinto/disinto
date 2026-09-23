#!/usr/bin/env bash
# =============================================================================
# tickets.sh — list all support tickets (admin only)
#
#     tickets
#
# Reads every line of $TICKETS_FILE and prints them parsed as a JSON array.
# Admin-gated: only a caller whose account row carries `"admin": true` may read
# the ticket log. Everyone else gets {"error":"not admin"} and a non-zero
# exit. An empty or missing ticket file yields an empty array ([]) for an
# admin caller.
#
# Output contract (stdout unless noted):
#   rc 0  -> a JSON array of ticket records (may be empty)
#   rc 1  -> {"error":"not admin"}            (caller's row is not admin)
#           {"error":"missing fingerprint"} to stderr + rc 1 (miswire)
#
# The admin flag is a property of the caller's account row (see
# lib/accounts.sh). The check fails closed: a missing field, a missing row,
# or anything that is not exactly true means "not admin".
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"

TICKETS_FILE="${TICKETS_FILE:-/var/lib/disinto/tickets.jsonl}"

# ── fingerprint (set by dispatch.sh; validated via require_dispatch_fp) ──────
fp="$(require_dispatch_fp)" || exit 1

# Admin gate, failing closed on anything not exactly true.
require_admin "$fp"

# JSONL -> JSON array. An empty or missing file yields [].
if [[ -f "$TICKETS_FILE" ]]; then
  jq -s '.' "$TICKETS_FILE"
else
  printf '[]\n'
fi
exit 0
