#!/usr/bin/env bash
# =============================================================================
# credits-grant.sh — grant credits to a fingerprint (admin only)
#
#     credits-grant <fp> <n>
#
# The manual credit faucet — the only way credits exist until the Stripe
# webhook lands (later issue; no Stripe call here, and no debiting here either:
# spending is a separate verb). dispatch.sh exports DISPATCH_FP before
# exec'ing, so the *caller* is the account identified by DISPATCH_FP; <fp>
# is the grant target, which may be the caller's own fingerprint.
#
# Admin-gated: only a caller whose account row carries `"admin": true` may
# grant; the gate checks the *caller* and fails closed — a missing row or
# field, or anything not exactly true, means "not admin". A denied grant
# writes nothing: it never even creates a row for the target.
#
# Validation:
#   <fp> — the target's SHA256 fingerprint (the account-ledger regex)
#   <n>  — a positive integer 1..1000000
#
# Flow: validate -> admin gate -> account_ensure(<fp>) ->
#       account_add_credits(<fp>, <n>) -> print the target's updated row.
#
# Output contract (stdout unless noted):
#   rc 0  -> the target's updated compact account row (credits = old + <n>)
#   rc 1  -> {"error":"..."} with one of:
#       "bad arguments"       — not exactly two arguments
#       "invalid fingerprint" — <fp> fails the fingerprint regex
#       "bad amount"          — <n> is not an integer 1..1000000
#       "not admin"           — the caller's row is not admin (nothing written)
#     {"error":"missing fingerprint"} to stderr + rc 1 (miswire)
#   Every failure path returns before touching the ledger.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"

MAX_CREDIT_GRANT=1000000

# ── arguments ────────────────────────────────────────────────────────────────
[[ $# -eq 2 ]] \
  || fail_error "bad arguments"
target="$1"
n="$2"

# ── fingerprint (set by dispatch.sh; validated via require_dispatch_fp) ──────
fp="$(require_dispatch_fp)" || exit 1

# ── target fingerprint: the account-ledger regex (dispatch.sh's contract) ────
[[ "$target" =~ $FINGERPRINT_RE ]] \
  || fail_error "invalid fingerprint"

# ── amount: canonical positive integer (no leading zeros), 1..MAX_GRANT ─────
# Cap the digit count to 7 (MAX_CREDIT_GRANT is 7 digits). Without the cap, an
# unbounded input slips the *range* check: bash 64-bit (( )) arithmetic wraps
# mod 2^64 (18446744073709552116 -> 500, which passes 1..1000000) while jq's
# --argjson in account_add_credits() parses the *original* string and credits
# ~2^64, corrupting the ledger. With a 7-digit cap both agree on the value.
[[ "$n" =~ ^[1-9][0-9]{0,6}$ ]] \
  || fail_error "bad amount"
if (( n < 1 || n > MAX_CREDIT_GRANT )); then
  fail_error "bad amount"
fi

# ── admin gate: caller's row, failing closed on anything not exactly true ────
require_admin "$fp"

# ── credit the target row, then print its updated form ───────────────────────
if ! account_ensure "$target"; then
  printf '{"error":"failed to ensure target row"}\n' >&2
  exit 1
fi
if ! account_add_credits "$target" "$n"; then
  printf '{"error":"failed to add credits"}\n' >&2
  exit 1
fi
account_row "$target"
exit 0
