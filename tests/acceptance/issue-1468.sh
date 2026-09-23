#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1468.sh
#
# Issue #1468: feat(edge): credits balance and admin grant
#
# Exercises verbs/credits.sh and verbs/credits-grant.sh against a throwaway
# ACCOUNTS_FILE in a mktemp dir — no live services, no sshd, and never
# /var/lib/disinto or /etc/ssh. The verbs are run directly with DISPATCH_FP
# exported, per the dispatcher contract (see issue-1467.sh for the pattern).
#
#   AC1  credits prints {"fp":"...","credits":N} for the caller — the seeded
#        balance for an existing row, and 0 for a fresh row.
#   AC2  non-admin credits-grant -> {"error":"not admin"}, rc!=0, and the
#        ledger is byte-identical (nothing credited; the target row is never
#        created).
#   AC3  admin credits-grant FP N -> rc 0, prints FP's updated row with credits
#        incremented by exactly N; also works for an unregistered target, whose
#        row is created with exactly N (account_ensure).
#   AC4  amounts 0, -5, 1000001, "5.5" and "abc" are rejected ({"error":"bad
#        amount"}, rc!=0, ledger untouched).
#
# Run via: tools/run-acceptance.sh 1468
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat date

CREDITS_SCRIPT="$REPO_ROOT/tools/edge-control/verbs/credits.sh"
GRANT_SCRIPT="$REPO_ROOT/tools/edge-control/verbs/credits-grant.sh"
ACCOUNTS_LIB="$REPO_ROOT/tools/edge-control/lib/accounts.sh"

ac_assert_file "$CREDITS_SCRIPT"  "verbs/credits.sh is missing"
ac_assert_file "$GRANT_SCRIPT"    "verbs/credits-grant.sh is missing"
ac_assert_file "$ACCOUNTS_LIB"    "lib/accounts.sh is missing"

# ── Fixtures: throwaway ledger, fingerprints ─────────────────────────────────
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"

# Make a ledger row for <fp> (status=pending) with a name, admin flag, and
# credit balance — the same shape dispatch.sh + account_ensure produce.
seed_row() {
  local fp="$1" name="$2" admin="$3" credits="$4"
  local tmp
  tmp="$ACCOUNTS_FILE.tmp"
  jq --arg fp "$fp" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
     --arg name "$name" --arg admin "$admin" --argjson credits "$credits" \
     '.accounts[$fp] = {fingerprint: $fp, status: "pending", credits: $credits,
      name: (if $name == "" then null else $name end),
      admin: (if $admin == "true" then true else false end),
      created_at: $now}' \
     "$ACCOUNTS_FILE" > "$tmp" \
    || ac_fail "seed_row: cannot seed row for $fp"
  mv "$tmp" "$ACCOUNTS_FILE"
}

# Valid SHA256 fingerprints: "SHA256:" + exactly 43 base64url chars.
FP_A="SHA256:$(printf 'A%.0s' {1..43})"
FP_B="SHA256:$(printf 'B%.0s' {1..43})"
FP_ADMIN="SHA256:$(printf 'C%.0s' {1..43})"
[[ "$FP_A" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP_A"

# A non-admin caller with a seeded balance, plus a *pending* admin so the gate
# is provably independent of status. FP_B is left unregistered on purpose:
# only a grant may create its row.
seed_row "$FP_A"     "payer"   "false" 7
seed_row "$FP_ADMIN" "admin"   "true"  0

# ── Run the verbs exactly as the dispatcher would ─────────────────────────────
run_credits() {
  local fp="$1"
  RC=0
  OUT="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$fp" \
          bash "$CREDITS_SCRIPT")" || RC=$?
}
run_grant() {
  local fp="$1" target="$2" n="$3"
  RC=0
  OUT="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$fp" \
          bash "$GRANT_SCRIPT" "$target" "$n")" || RC=$?
}

# The row's credits in the ledger, or -1 when the row is absent.
balance_of() {
  jq -r --arg fp "$1" '(.accounts // {})[$fp].credits // -1' "$ACCOUNTS_FILE"
}

# ── AC1. credits prints the caller's numeric balance ─────────────────────────
run_credits "$FP_A"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: credits should succeed (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"fp":"'"$FP_A"'","credits":7}' ]]; then
  ac_fail "AC1: credits output is wrong: $OUT"
fi

run_credits "$FP_ADMIN"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: admin's credits should succeed (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"fp":"'"$FP_ADMIN"'","credits":0}' ]]; then
  ac_fail "AC1: admin's credits output is wrong: $OUT"
fi
ac_log "AC1: credits prints {\"fp\":...,\"credits\":N} for the caller"

# ── AC2. non-admin grant: denied, and nothing written ─────────────────────────
acct_before="$(cat "$ACCOUNTS_FILE")"
run_grant "$FP_A" "$FP_B" 5
if [ "$RC" -eq 0 ]; then
  ac_fail "AC2: non-admin grant should be denied (rc=0, out=$OUT)"
fi
if ! jq -e '.error == "not admin"' <<<"$OUT" >/dev/null 2>&1; then
  ac_fail "AC2: expected {\"error\":\"not admin\"}, got: $OUT"
fi
if [ "$acct_before" != "$(cat "$ACCOUNTS_FILE")" ]; then
  ac_fail "AC2: a denied non-admin grant mutated the ledger (before/after differ)"
fi
if jq -e --arg fp "$FP_B" '(.accounts // {})[$fp] != null' "$ACCOUNTS_FILE" \
    >/dev/null 2>&1; then
  ac_fail "AC2: a row was created for the target by a denied grant"
fi
ac_log "AC2: non-admin grant -> not admin, ledger byte-identical"

# ── AC3. admin grant adds exactly N (and creates a row for a new target) ─────
run_grant "$FP_ADMIN" "$FP_A" 5
if [ "$RC" -ne 0 ]; then
  ac_fail "AC3: admin grant should succeed (rc=$RC, out=$OUT)"
fi
if ! jq -e --arg fp "$FP_A" '.fingerprint == $fp and .credits == 12' \
     <<<"$OUT" >/dev/null 2>&1; then
  ac_fail "AC3: the printed row is not FP_A's updated row with credits 12: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 12 ]]; then
  ac_fail "AC3: FP_A's ledger credits are not 12 after a grant of 5"
fi

# Grant to an unregistered target: the row is created with exactly N.
run_grant "$FP_ADMIN" "$FP_B" 100
if [ "$RC" -ne 0 ]; then
  ac_fail "AC3: admin grant to a new target should succeed (rc=$RC, out=$OUT)"
fi
if [[ "$(balance_of "$FP_B")" != 100 ]]; then
  ac_fail "AC3: the new target's ledger credits are not 100 after a grant of 100"
fi
ac_log "AC3: admin grant adds exactly N (incl. creating a row for a new target)"

# ── AC4. zero, negative, out-of-range and non-integer amounts are rejected ────
for amount in 0 -5 1000001 5.5 abc; do
  run_grant "$FP_ADMIN" "$FP_A" "$amount"
  if [ "$RC" -eq 0 ]; then
    ac_fail "AC4: amount $amount should be rejected (rc=0, out=$OUT)"
  fi
  if ! jq -e '.error == "bad amount"' <<<"$OUT" >/dev/null 2>&1; then
    ac_fail "AC4: expected {\"error\":\"bad amount\"} for $amount, got: $OUT"
  fi
  if [[ "$(balance_of "$FP_A")" != 12 ]]; then
    ac_fail "AC4: rejected amount $amount changed the balance"
  fi
done
ac_log "AC4: 0, -5, 1000001, 5.5, abc -> bad amount, nothing written"
ac_pass
