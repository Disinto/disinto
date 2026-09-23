#!/usr/bin/env bash
# credits: print this caller's credit balance.
#
#     credits
#
# A report verb: no arguments, no writes. dispatch.sh exports DISPATCH_FP and
# account_ensure()'d the row before exec'ing a verb, so the balance is read
# straight from the ledger; an absent row/credits falls back to 0 rather than
# an error.
#
# Output contract (JSON on stdout, one line; exit code):
#   rc 0  -> {"fp":"<DISPATCH_FP>","credits":<N>}  (N is the row's credits)
#   rc 1  -> {"error":"missing fingerprint"} to stderr (miswire)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"

fp="$(require_dispatch_fp)" || exit 1
jq -c --arg fp "$fp" \
     '{fp: $fp, credits: ((.accounts // {})[$fp].credits // 0)}' "$ACCOUNTS_FILE"
exit 0
