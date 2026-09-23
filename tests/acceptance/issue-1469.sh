#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1469.sh
#
# Issue #1469: feat(edge): credits-buy returns a Stripe Checkout URL
#
# Exercises verbs/credits-buy.sh against a throwaway ACCOUNTS_FILE in a mktemp
# dir. The Stripe call is intercepted by a fake `curl` dropped at the front of
# PATH (so the verb's request never reaches api.stripe.com or any live host).
# The fake records the POST body and the basic-auth user it saw, and can be
# told to return a chosen HTTP status (default 200) — so the 2xx and non-2xx
# branches are both exercised locally.
#
#   AC1  Unset STRIPE_SECRET_KEY/PRICE_ID -> {"error":"payments not configured"}
#        rc!=0, and the stub is never invoked (no socket opened).
#   AC2  A stubbed 200 POST carries client_reference_id equal to the caller
#        fingerprint (DISPATCH_FP), plus mode=payment, the configured price and
#        the success/cancel URLs; the basic auth is the secret key.
#   AC3  A stubbed 200 response prints {"url":"..."} (rc 0) and leaves credits
#        unchanged; a stubbed non-2xx prints {"error":"checkout failed"} (rc!=0)
#        without echoing any Stripe body, credits still unchanged.
#   AC4  stdin is not parsed as payment data: feeding a card number/PAN/CVC on
#        stdin changes nothing (identical stdout, rc and POST body; card data
#        never leaks out).
#
# Run via: tools/run-acceptance.sh 1469
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat date env

BUY_SCRIPT="$REPO_ROOT/tools/edge-control/verbs/credits-buy.sh"
ACCOUNTS_LIB="$REPO_ROOT/tools/edge-control/lib/accounts.sh"

ac_assert_file "$BUY_SCRIPT" "verbs/credits-buy.sh is missing"
ac_assert_file "$ACCOUNTS_LIB" "lib/accounts.sh is missing"

# ── Fixtures: throwaway ledger, fingerprints ─────────────────────────────────
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
seed_row "$FP_A" "payer" "false" 7

# ── Stripe stub: a fake `curl` at the front of PATH ──────────────────────────
# Captures the POST body (-d/--data) and basic-auth user (-u/--user) into the
# files named by STUB_BODY_FILE / STUB_AUTH_FILE, and echoes body + newline +
# http_code (like curl -w $'\n%{http_code}'). STUB_HTTP_CODE sets the status
# (default 200 for the checkout endpoint, 404 elsewhere). It exits 0 always
# (real curl exits 0 on HTTP errors without -f), so the verb classifies by the
# code, not the process rc.
STUB_BIN="$TMP_DIR/stub"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'STUB_CURL'
#!/usr/bin/env bash
set -u

# Proof that this stub was invoked at all (the unconfigured path must NOT reach
# it, i.e. must not open a socket).
if [[ -n "${STUB_INVOKED_FILE:-}" ]]; then
  touch "$STUB_INVOKED_FILE" 2>/dev/null || true
fi

args=("$@")
n=${#args[@]}
i=0
body=""
auth=""
url=""
while (( i < n )); do
  arg="${args[i]}"
  case "$arg" in
    -d)       i=$((i + 1)); body="${args[i]}"; i=$((i + 1)) ;;
    -d=*)     body="${arg#-d=}"; i=$((i + 1)) ;;
    --data)   i=$((i + 1)); body="${args[i]}"; i=$((i + 1)) ;;
    --data=*) body="${arg#--data=}"; i=$((i + 1)) ;;
    -u)       i=$((i + 1)); auth="${args[i]}"; i=$((i + 1)) ;;
    -u=*)     auth="${arg#-u=}"; i=$((i + 1)) ;;
    --user)   i=$((i + 1)); auth="${args[i]}"; i=$((i + 1)) ;;
    *)
      if [[ "$arg" == "http://"* || "$arg" == "https://"* || "$arg" == "localhost:"* ]]; then
        [[ -z "$url" ]] && url="$arg"
      fi
      i=$((i + 1)) ;;
  esac
done

# Record what the verb sent.
[[ -n "${STUB_BODY_FILE:-}" ]] && printf '%s' "$body" > "$STUB_BODY_FILE"
[[ -n "${STUB_AUTH_FILE:-}" ]] && printf '%s' "$auth" > "$STUB_AUTH_FILE"

# Response code: default 200 on the checkout endpoint, 404 elsewhere.
case "$url" in
  *"/v1/checkout/sessions") code="${STUB_HTTP_CODE:-200}" ;;
  *)                       code="${STUB_HTTP_CODE:-404}" ;;
esac

# Body: STUB_BODY if set, else a default session JSON when 2xx, else empty.
if [[ -n "${STUB_BODY:-}" ]]; then
  resp_body="$STUB_BODY"
elif [[ "$code" =~ ^2[0-9]{2}$ ]]; then
  resp_body=$(printf '{"id":"si_123","client_reference_id":"x","mode":"payment","url":"https://checkout.example/session/abc123"}')
else
  resp_body=""
fi

printf '%s\n%s\n' "$resp_body" "$code"
STUB_CURL
chmod +x "$STUB_BIN/curl"

# ── Env: fake Stripe API + capture files ─────────────────────────────────────
STRIPE_API_BASE="http://127.0.0.1:9999"
STRIPE_SECRET_KEY="sk_test_stub_1234567890abcdef"
STRIPE_PRICE_ID="price_1234567890abcd"
STRIPE_SUCCESS_URL="https://example.com/success"
STRIPE_CANCEL_URL="https://example.com/cancel"
CAPTURE_BODY="$TMP_DIR/curl_body.json"
CAPTURE_AUTH="$TMP_DIR/curl_auth.txt"
STUB_INVOKED="$TMP_DIR/stub_invoked"
export STUB_BODY_FILE="$CAPTURE_BODY" STUB_AUTH_FILE="$CAPTURE_AUTH" \
       STUB_INVOKED_FILE="$STUB_INVOKED" \
       STRIPE_API_BASE STRIPE_SECRET_KEY STRIPE_PRICE_ID \
       STRIPE_SUCCESS_URL STRIPE_CANCEL_URL

# ── Run credits-buy exactly as the dispatcher would (fake curl on PATH) ──────
# $1 = DISPATCH_FP (caller fp).  $2 = stdin source file (/dev/null = none).
# $3 = STUB_HTTP_CODE to force ("" leaves the stub default of 200).
run_buy() {
  local fp="$1" in="$2" code="$3"
  RC=0
  OUT="$(STUB_HTTP_CODE="$code" \
    STUB_BODY_FILE="$CAPTURE_BODY" STUB_AUTH_FILE="$CAPTURE_AUTH" \
    STUB_INVOKED_FILE="$STUB_INVOKED" \
    ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$fp" \
    PATH="$STUB_BIN:$PATH" \
    bash "$BUY_SCRIPT" <"$in" 2>/dev/null)" || RC=$?
}

# The row's credits in the ledger (7 for the seeded FP_A).
balance_of() {
  jq -r --arg fp "$1" '(.accounts // {})[$fp].credits // -1' "$ACCOUNTS_FILE"
}

# ── AC1. unset Stripe env -> payments not configured, no socket ──────────────
rm -f "$STUB_INVOKED"
RC=0
OUT="$(env -u STRIPE_SECRET_KEY -u STRIPE_PRICE_ID \
    STUB_BODY_FILE="$CAPTURE_BODY" STUB_AUTH_FILE="$CAPTURE_AUTH" \
    STUB_INVOKED_FILE="$STUB_INVOKED" \
    ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$FP_A" \
    PATH="$STUB_BIN:$PATH" \
    bash "$BUY_SCRIPT" 2>/dev/null)" || RC=$?

if [ "$RC" -eq 0 ]; then
  ac_fail "AC1: unconfigured should fail (rc=0, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"payments not configured"}' ]]; then
  ac_fail "AC1: expected {\"error\":\"payments not configured\"}, got: $OUT"
fi
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC1: stub was invoked (a socket was opened) despite unconfigured payments"
fi
ac_log "AC1: unconfigured -> payments not configured, no socket opened"

# ── AC2. configured 2xx POST carries the fingerprint; basic auth is the key ─
rm -f "$STUB_INVOKED"
run_buy "$FP_A" /dev/null "200"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC2: configured buy should succeed (rc=$RC, out=$OUT)"
fi
if [ ! -f "$STUB_INVOKED" ]; then
  ac_fail "AC2: stub was never invoked on the configured path"
fi
if ! jq -e --arg fp "$FP_A" '.client_reference_id == $fp and .mode == "payment" and .line_items[0].price == "price_1234567890abcd"' "$CAPTURE_BODY" >/dev/null 2>&1; then
  ac_fail "AC2: POST body wrong (ref/mode/price): $(cat "$CAPTURE_BODY")"
fi
if ! jq -e --arg s "$STRIPE_SUCCESS_URL" --arg c "$STRIPE_CANCEL_URL" '.success_url == $s and .cancel_url == $c' "$CAPTURE_BODY" >/dev/null 2>&1; then
  ac_fail "AC2: success_url/cancel_url wrong: $(cat "$CAPTURE_BODY")"
fi
if [[ "$(cat "$CAPTURE_AUTH")" != "${STRIPE_SECRET_KEY}:" ]]; then
  ac_fail "AC2: basic auth wrong: $(cat "$CAPTURE_AUTH")"
fi
ac_log "AC2: 200 POST -> client_reference_id=<fp>, price, urls, secret-key auth"

# ── AC3. 200 prints the url, credits unchanged; non-2xx -> checkout failed ──
if [[ "$OUT" != '{"url":"https://checkout.example/session/abc123"}' ]]; then
  ac_fail "AC3: expected {\"url\":\"https://checkout.example/session/abc123\"}, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 7 ]]; then
  ac_fail "AC3: buying credits changed the balance (expected 7)"
fi

rm -f "$STUB_INVOKED"
run_buy "$FP_A" /dev/null "500"
if [ "$RC" -eq 0 ]; then
  ac_fail "AC3: non-2xx should fail (rc=0, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"checkout failed"}' ]]; then
  ac_fail "AC3: expected {\"error\":\"checkout failed\"}, got: $OUT"
fi
if [[ "$OUT" == *"abc123"* ]] || [[ "$(cat "$CAPTURE_BODY" 2>/dev/null)" == *"abc123"* ]]; then
  ac_fail "AC3: a Stripe body leaked on the non-2xx path"
fi
if [[ "$(balance_of "$FP_A")" != 7 ]]; then
  ac_fail "AC3: a failed checkout changed the balance"
fi
ac_log "AC3: 200 -> url, credits unchanged; non-2xx -> checkout failed, no body leaked"

# ── AC4. stdin is not parsed as payment data ─────────────────────────────────
CARD="4242 4242 4242 4242 001"
CARD_FILE="$TMP_DIR/card.txt"
printf '%s\n' "$CARD" > "$CARD_FILE"

# baseline: empty stdin
run_buy "$FP_A" /dev/null "200"
OUT_NOIN="$OUT"; RC_NOIN="$RC"
BODY_NOIN="$(cat "$CAPTURE_BODY")"
# card on stdin
run_buy "$FP_A" "$CARD_FILE" "200"
OUT_IN="$OUT"; RC_IN="$RC"
BODY_IN="$(cat "$CAPTURE_BODY")"

if [[ "$OUT_NOIN" != "$OUT_IN" ]]; then
  ac_fail "AC4: stdout differs with card stdin (no-in: $OUT_NOIN, in: $OUT_IN)"
fi
if [[ "$RC_NOIN" != "$RC_IN" ]]; then
  ac_fail "AC4: rc differs with card stdin ($RC_NOIN vs $RC_IN)"
fi
if [[ "$OUT_IN" == *"$CARD"* ]] || [[ "$OUT_IN" == *"4242"* ]]; then
  ac_fail "AC4: payment data from stdin leaked into stdout: $OUT_IN"
fi
if [[ "$BODY_NOIN" != "$BODY_IN" ]]; then
  ac_fail "AC4: POST body differs with card stdin (without: $BODY_NOIN, within: $BODY_IN)"
fi
ac_log "AC4: card/PAN/CVC on stdin is ignored (identical stdout, rc, POST body)"

ac_pass
