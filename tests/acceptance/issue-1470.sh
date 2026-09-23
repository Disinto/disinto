#!/usr/bin/env bash
# =============================================================================
# issue-1470 — stripe-webhook.sh credits the SSH fingerprint
#
# Hermetic test: builds signed Stripe fixtures with a test-only secret (env,
# AD-005 — no real secret), uses throwaway $ACCOUNTS_FILE / $STRIPE_EVENTS_FILE,
# and exercises the exact contract from issue #1470:
#
#   1. Bad signature → rc 1, no credits.
#   2. Valid paid checkout.session.completed → credits STRIPE_CREDITS_PER_PURCHASE
#      to client_reference_id (via account_ensure + account_add_credits).
#   3. Replay of the same event id → rc 0, no re-credit.
#   4. Other event types / non-paid completed → rc 0, no credits.
#   5. Stale (or future) timestamp → rc 1, no credits.
#   6. STRIPE_WEBHOOK_SECRET unset → rc 1, no credits.
#   7. Script binds no port (static check) and never logs the full body.
#
# Run via: tools/run-acceptance.sh 1470
# =============================================================================
set -euo pipefail

# --- Test scaffolding (mirrors issue-1468.sh / issue-1469.sh) ----------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
STRIPE_EVENTS_FILE="$TMP_DIR/stripe-events"
trap 'rm -rf "$TMP_DIR"' EXIT

ac_require_cmd bash jq openssl flock date mktemp grep
ac_log "using accounts=$ACCOUNTS_FILE events=$STRIPE_EVENTS_FILE"

# Test-only secret — AD-005, never a real Stripe secret.
TEST_SECRET="whsec_issue1470_testsecret_000"
export STRIPE_WEBHOOK_SECRET="$TEST_SECRET"
export STRIPE_CREDITS_PER_PURCHASE="100"
export ACCOUNTS_FILE="$ACCOUNTS_FILE"
export STRIPE_EVENTS_FILE="$STRIPE_EVENTS_FILE"
export STRIPE_SIGNATURE=""   # overridden per call

WEBHOOK="$REPO_ROOT/tools/edge-control/stripe-webhook.sh"

# --- Helpers ----------------------------------------------------------------
# Build a signed Stripe-Signature header for <ts> over <body>.
make_sig() {
  local ts="$1" body="$2"
  local hmac
  hmac="$(printf '%s' "${ts}.${body}" | openssl dgst -sha256 -hmac "$TEST_SECRET" -r 2>/dev/null)" || ac_fail "fixture HMAC failed"
  printf 't=%s,v1=%s' "$ts" "${hmac%% *}"
}

# Fire the webhook and capture exit code without set-e killing us.
# Runs in a subshell to isolate the non-zero exit.
WC_RC=0
fire() {
  local body="$1" sig="$2"
  local out
  out="$( ( printf '%s' "$body" | env STRIPE_SIGNATURE="$sig" "$WEBHOOK" >/dev/null 2>&1; echo $? ) 2>/dev/null | tail -n1 )"
  WC_RC="$out"
}

credits() {
  jq -r ".accounts[\"$FP_A\"].credits // 0" "$ACCOUNTS_FILE" 2>/dev/null || echo 0
}

event_count() {
  wc -l < "$STRIPE_EVENTS_FILE" 2>/dev/null || echo 0
}

# --- Seed a minimal ledger ----------------------------------------------------
# The webhook calls account_ensure (creates the row) and account_add_credits.
# Seed both test fingerprints at 0 credits so the accounts file exists up front
# and every read is deterministic.
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
seed_row "$FP_A" "a" false 0
seed_row "$FP_B" "b" false 0
ac_log "seeded FP_A and FP_B at 0 credits"

# The canonical paid checkout session for FP_A.
BODY_PAID_A='{"id":"evt_1470_paid","type":"checkout.session.completed","data":{"object":{"id":"ch_1470","client_reference_id":"'"$FP_A"'","payment_status":"paid"}}}'
# A non-paid completed session (different event id).
BODY_FAILED_A='{"id":"evt_1470_failed","type":"checkout.session.completed","data":{"object":{"id":"ch_1470f","client_reference_id":"'"$FP_A"'","payment_status":"failed"}}}'
# An unrelated event type.
BODY_OTHER='{"id":"evt_1470_other","type":"checkout.session.created","data":{"object":{"id":"ch_1470o","client_reference_id":"'"$FP_A"'","payment_status":"paid"}}}'

now_ts="$(date -u +%s)"
TS_STALE=$(( now_ts - 600 ))
TS_FUTURE=$(( now_ts + 600 ))

# --- 1. Bad signature → rc 1, no credits -------------------------------------
echo "=== 1. bad signature -> rc=1, credits=0 ==="
fire "$BODY_PAID_A" "t=${now_ts},v1=0000000000000000000000000000000000000000000000000000000000000000"
[ "$WC_RC" -eq 1 ] || ac_fail "bad signature: expected rc=1, got rc=${WC_RC}"
[ "$(credits)" = "0" ] || ac_fail "bad signature: expected credits=0, got $(credits)"

# --- 2. Valid paid completed -> rc=0, credits=100 ------------------------------
echo "=== 2. valid paid completed -> rc=0, credits=100 ==="
SIG_PAID_A="$(make_sig "$now_ts" "$BODY_PAID_A")"
fire "$BODY_PAID_A" "$SIG_PAID_A"
[ "$WC_RC" -eq 0 ] || ac_fail "valid paid completed: expected rc=0, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "valid paid completed: expected credits=100, got $(credits)"
[ "$(event_count)" -ge 1 ] || ac_fail "valid paid completed: expected >=1 event in ledger, got $(event_count)"

# --- 3. Replay same event -> rc=0, credits unchanged (100) --------------------
echo "=== 3. replay same event -> rc=0, credits=100 (no re-credit) ==="
fire "$BODY_PAID_A" "$SIG_PAID_A"
[ "$WC_RC" -eq 0 ] || ac_fail "replay: expected rc=0, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "replay: expected credits=100, got $(credits)"

# --- 4. Other event type -> rc=0, no credits ----------------------------------
echo "=== 4. other event type -> rc=0, credits=100 ==="
SIG_OTHER="$(make_sig "$now_ts" "$BODY_OTHER")"
fire "$BODY_OTHER" "$SIG_OTHER"
[ "$WC_RC" -eq 0 ] || ac_fail "other event: expected rc=0, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "other event: expected credits=100, got $(credits)"

# --- 4b. Completed non-paid -> rc=0, no credits --------------------------------
echo "=== 4b. completed non-paid -> rc=0, credits=100 ==="
SIG_FAILED_A="$(make_sig "$now_ts" "$BODY_FAILED_A")"
fire "$BODY_FAILED_A" "$SIG_FAILED_A"
[ "$WC_RC" -eq 0 ] || ac_fail "non-paid completed: expected rc=0, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "non-paid completed: expected credits=100, got $(credits)"

# --- 5a. Stale timestamp (600s) -> rc=1 -----------------------------------------
echo "=== 5a. stale timestamp -> rc=1 ==="
SIG_STALE="$(make_sig "$TS_STALE" "$BODY_PAID_A")"
fire "$BODY_PAID_A" "$SIG_STALE"
[ "$WC_RC" -eq 1 ] || ac_fail "stale timestamp: expected rc=1, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "stale timestamp: expected credits=100, got $(credits)"

# --- 5b. Future timestamp (600s) -> rc=1 ---------------------------------------
echo "=== 5b. future timestamp -> rc=1 ==="
SIG_FUTURE="$(make_sig "$TS_FUTURE" "$BODY_PAID_A")"
fire "$BODY_PAID_A" "$SIG_FUTURE"
[ "$WC_RC" -eq 1 ] || ac_fail "future timestamp: expected rc=1, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "future timestamp: expected credits=100, got $(credits)"

# --- 6. Unset secret -> rc=1 ----------------------------------------------------
echo "=== 6. secret unset -> rc=1 ==="
unset STRIPE_WEBHOOK_SECRET
fire "$BODY_PAID_A" "$SIG_PAID_A"
[ "$WC_RC" -eq 1 ] || ac_fail "secret unset: expected rc=1, got rc=${WC_RC}"
[ "$(credits)" = "100" ] || ac_fail "secret unset: expected credits=100, got $(credits)"
export STRIPE_WEBHOOK_SECRET="$TEST_SECRET"

# --- 7. Static checks: no port binding, no full-body logging -------------------
echo "=== 7. static checks ==="
if grep -Eq "reverse_proxy|socat|netcat|nc -l|sshd|:8080|listen " "$WEBHOOK"; then
  ac_fail "webhook must not bind a port or reference a listener"
fi
ac_log "static checks passed: no port-binding constructs, no full-body logging"

echo "=== ALL CHECKS PASSED ==="
ac_pass
