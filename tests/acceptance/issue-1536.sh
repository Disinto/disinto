#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1536.sh
#
# Issue #1536: fix(edge): jev debits only a real answer and retries 429
#
# Exercises the *new* behavior of verbs/jev.sh against a throwaway $ACCOUNTS_FILE
# in a mktemp dir. The TypeSafe call is intercepted by a *counting* fake `curl`
# dropped at the front of PATH, plus a no-op fake `sleep` (so the 1s/2s backoff
# does not slow this run). The counting stub can return a *different* HTTP
# status and body on each attempt (driven by newline-separated STUB_CODES /
# STUB_BODIES), and appends a line per call so the test can count attempts.
#
#   AC1  429,429,200 with an `answers` body -> rc 0 on attempt 3, one debit,
#        body echoed, and the log's model is the body's .model (wins over the
#        request model). 3 invocations.
#   AC2  200 with a body lacking `answers` -> rc 1, stdout {"error":"jev failed"},
#        no debit, no body echo, 1 invocation (200 not retried).
#   AC3  500 -> rc 1, no debit, 1 invocation (500 not retried).
#   AC4  429,429,429 (retries exhausted) -> rc 1, no debit, 3 attempts.
#   AC5  529,529,200 with an `answers` body -> rc 0 on attempt 3, one debit
#        (covers 529 as well as 429). 3 invocations.
#   AC6  200 with an `answers` body that has no .model -> rc 0, one debit, and
#        the log's model falls back to the request model. 1 invocation.
#
# Static pre-flight: jev.sh must bound the request with `--max-time 20`,
# discard curl's stderr, reference the 429/529 retry codes, and back off with
# `sleep`.
#
# Contract: last line of stdout is PASS on success, "FAIL: <reason>" otherwise.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../" && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat date printf tr env chmod

JEV="$REPO_ROOT/tools/edge-control/verbs/jev.sh"
SCOPE_PACK="$REPO_ROOT/tools/edge-control/packs/scope.json"

ac_assert_file "$JEV" "verbs/jev.sh is missing"
ac_assert_file "$SCOPE_PACK" "packs/scope.json is missing"

# ── Fixtures: throwaway ledger ────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"

# seed_row emits pending rows, but jev requires status == "approved" — flip
# the row this test exercises to "approved". (issue-1471.sh does the same.)
approve_row() {
  local fp="$1"
  jq --arg fp "$fp" '.accounts[$fp].status = "approved"' "$ACCOUNTS_FILE" \
    > "${ACCOUNTS_FILE}.tmp" || ac_fail "cannot flip $fp to approved"
  mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"
}

# The bodies the counting stub returns. The "MODEL" variant carries a .model so
# we can prove the log uses the body's .model over the request model; the
# "NOMODEL" variant has no .model so we can prove the fallback to the request
# model.
ANSWERS_MODEL='{"model":"jev-1.13.0","answers":{"one_concept":{"type":"noul","noul":0.5}}}'
ANSWERS_NOMODEL='{"answers":{"one_concept":{"type":"noul","noul":0.5}}}'

# ── Counting stub: a fake curl + a no-op sleep at the front of PATH ──────────
export STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/curl" <<'STUB_EOF'
#!/usr/bin/env bash
# Counting TypeSafe stub for tests/acceptance/issue-1536.sh.
#
# Behavior per invocation is driven by two newline-separated env vars (one
# entry per attempt; out-of-range or a missing entry falls back to the last
# entry, or to a per-code default):
#   STUB_CODES  -- HTTP status to report on attempt n
#   STUB_BODIES -- body to report on attempt n
# The stub appends one line per call to STUB_INVOKED_FILE so the test can
# count attempts (and assert whether a status was (re)tried). It prints the
# body then the status as two lines (matching jev.sh's -w $'\n%{http_code}'
# parsing). Command args (payload, headers, URL, -w, --max-time, ...) are
# consumed but not asserted on.
set -u

INVOKED_FILE="${STUB_INVOKED_FILE:?}"
[ -f "$INVOKED_FILE" ] || : > "$INVOKED_FILE"
n=$(( ($(wc -l < "$INVOKED_FILE" 2>/dev/null || echo 0)) + 1 ))
printf 'x\n' >> "$INVOKED_FILE"

get_nth() {
  local seq="$1" n="$2"
  local -a a=()
  [[ -n "$seq" ]] && mapfile -t a <<< "$seq"
  if (( n <= ${#a[@]} )); then
    printf '%s' "${a[n-1]}"
  elif (( ${#a[@]} > 0 )); then
    printf '%s' "${a[${#a[@]}-1]}"
  else
    printf ''
  fi
}

code="$(get_nth "${STUB_CODES:-200}" "$n")"
body="$(get_nth "${STUB_BODIES:-}" "$n")"
if [[ -z "$body" ]]; then
  case "$code" in
    2*) body='{"status":"ok"}' ;;
    *)  body="" ;;
  esac
fi
if [[ -n "$body" ]]; then
  printf '%s\n%s\n' "$body" "$code"
else
  printf '\n%s\n' "$code"
fi
STUB_EOF
chmod +x "$STUB_DIR/curl"

# No-op sleep: jev.sh's 1s/2s backoff must not slow this acceptance run.
cat > "$STUB_DIR/sleep" <<'SLEEP_EOF'
#!/usr/bin/env bash
# No-op sleep so jev.sh's backoff does not delay this acceptance test.
exit 0
SLEEP_EOF
chmod +x "$STUB_DIR/sleep"

# ── Run helpers ───────────────────────────────────────────────────────────────
export STUB_INVOKED_FILE="$TMP_DIR/stub/invoked.txt"
export STUB_BODY_FILE="$TMP_DIR/stub/post-body.txt"
export STUB_URL_FILE="$TMP_DIR/stub/url.txt"
export TYPESAFE_API_URL="http://127.0.0.1:9999"
export API_KEY="test-key-1536"
# A request model distinct from the body's .model, so the "body's .model wins"
# and the "fall back to request model" branches are both observable in the log.
export JEV_MODEL="jev-request-9.9.9"

# A distinctive state to assert never leaks into the log.
STATE='{"topic":"the meaning of everything","note":"this-state-must-not-leak"}'

# $1=fp $2=pack_id $3=stdin-state $4=api_key ("" = unset) $5=codes $6=bodies
#   codes/bodies are newline-separated, one entry per attempted request; they
#   drive the counting stub's per-attempt status/body.
run_jev() {
  local fp="$1" pack_id="$2" state="$3" api_key="${4:-}" \
        codes="${5:-}" bodies="${6:-}"
  local errfile
  errfile="$TMP_DIR/jev-stderr.txt"
  : > "$errfile"
  RC=0
  OUT="$(
    # Key set or unset exactly as required (subshell => no leak to the test).
    if [[ -n "$api_key" ]]; then
      export TYPESAFE_API_KEY="$api_key"
    else
      unset TYPESAFE_API_KEY
    fi
    printf '%s' "$state" |
      STUB_INVOKED_FILE="$STUB_INVOKED_FILE" \
      STUB_CODES="$codes" \
      STUB_BODIES="$bodies" \
      STUB_BODY_FILE="$STUB_BODY_FILE" STUB_URL_FILE="$STUB_URL_FILE" \
      ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$fp" \
      TYPESAFE_API_URL="$TYPESAFE_API_URL" \
      PATH="$STUB_DIR:$PATH" \
        bash "$JEV" "$pack_id" 2>"$errfile"
  )" || RC=$?
  ERR="$(cat "$errfile")"
}

balance_of() {
  jq -r --arg fp "$1" '(.accounts // {})[$fp].credits // ""' "$ACCOUNTS_FILE" 2>/dev/null \
    || echo 0
}

# One line of stderr per jev run; count it for the "no retry" / "exhausted"
# assertions.
invocations() {
  local count
  count="$(wc -l < "$STUB_INVOKED_FILE" 2>/dev/null || true)"
  printf '%d' "$count"
}

# Assert the stderr log is exactly $1 and that the state/key never leaked.
stderr_is() {
  local expected="$1"
  if [[ "$ERR" != "$expected" ]]; then
    ac_fail "stderr: expected '$expected', got: '$ERR'"
  fi
  if [[ "$ERR" == *"$STATE"* ]]; then
    ac_fail "state leaked into the stderr log"
  fi
  if [[ "$ERR" == *"$API_KEY"* ]]; then
    ac_fail "api key leaked into the stderr log"
  fi
}

# Seed + approve the row the ACs exercise (100 credits so we can debit several).
seed_row "$FP_A" "user-1536" "true" 100
approve_row "$FP_A"

# ── Static pre-flight: the curl bounds + retry wiring in jev.sh ──────────────
if ! grep -q -- '--max-time 20' "$JEV"; then
  ac_fail "jev.sh does not bound its request with --max-time 20"
fi
if ! grep -qF '2>/dev/null' "$JEV"; then
  ac_fail "jev.sh does not discard curl's stderr"
fi
if ! grep -qE '429|529' "$JEV"; then
  ac_fail "jev.sh does not reference the 429/529 retry codes"
fi
if ! grep -qE '\bsleep\b' "$JEV"; then
  ac_fail "jev.sh does not back off with sleep"
fi
ac_log "static: --max-time 20, discarded curl stderr, 429/529 + sleep wired"

# ── AC1. 429,429,200 -> success on attempt 3, body .model wins, one debit ────
rm -f "$STUB_INVOKED_FILE" "$STUB_BODY_FILE" "$STUB_URL_FILE"
codes=$'429\n429\n200'
# A single body entry repeats for every attempt; only the 200's body is echoed.
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" "$codes" "$ANSWERS_MODEL"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: 429,429,200 should succeed (rc=$RC, out=$OUT, err=$ERR)"
fi
if [[ "$OUT" != "$ANSWERS_MODEL" ]]; then
  ac_fail "AC1: expected the 200 answers body on stdout, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 99 ]]; then
  ac_fail "AC1: expected one debit (100->99), now $(balance_of "$FP_A")"
fi
if [[ "$(invocations)" != 3 ]]; then
  ac_fail "AC1: expected 3 attempts for 429,429,200, got $(invocations)"
fi
# The log model is the body's .model (jev-1.13.0), which differs from the
# request model (jev-request-9.9.9) — proving the body's .model wins.
stderr_is "jev fp=$FP_A pack=scope model=jev-1.13.0 status=200"
ac_log "AC1: 429,429,200 -> success on attempt 3, body .model wins, one debit"

# ── AC2. 200 without `answers` -> jev failed, no debit, 1 invocation ─────────
rm -f "$STUB_INVOKED_FILE" "$STUB_BODY_FILE" "$STUB_URL_FILE"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" "200"
if [ "$RC" -ne 1 ]; then
  ac_fail "AC2: 200 without answers should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"jev failed"}' ]]; then
  ac_fail "AC2: expected {\"error\":\"jev failed\"}, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 99 ]]; then
  ac_fail "AC2: 200-without-answers debited (now $(balance_of "$FP_A"))"
fi
if [[ "$(invocations)" != 1 ]]; then
  ac_fail "AC2: expected 1 attempt (200 not retried), got $(invocations)"
fi
# Body lacks .model -> log falls back to the request model.
stderr_is "jev fp=$FP_A pack=scope model=jev-request-9.9.9 status=200"
ac_log "AC2: 200 without answers -> jev failed, no debit, no retry"

# ── AC3. 500 -> jev failed, no debit, 1 invocation (not retried) ─────────────
rm -f "$STUB_INVOKED_FILE" "$STUB_BODY_FILE" "$STUB_URL_FILE"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" "500"
if [ "$RC" -ne 1 ]; then
  ac_fail "AC3: 500 should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"jev failed"}' ]]; then
  ac_fail "AC3: expected {\"error\":\"jev failed\"}, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 99 ]]; then
  ac_fail "AC3: 500 debited (now $(balance_of "$FP_A"))"
fi
if [[ "$(invocations)" != 1 ]]; then
  ac_fail "AC3: expected 1 attempt (500 not retried), got $(invocations)"
fi
stderr_is "jev fp=$FP_A pack=scope model=jev-request-9.9.9 status=500"
ac_log "AC3: 500 -> jev failed, no debit, no retry"

# ── AC4. 429,429,429 (exhausted) -> jev failed, no debit, 3 attempts ─────────
rm -f "$STUB_INVOKED_FILE" "$STUB_BODY_FILE" "$STUB_URL_FILE"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" $'429\n429\n429'
if [ "$RC" -ne 1 ]; then
  ac_fail "AC4: exhausted 429 retries should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"jev failed"}' ]]; then
  ac_fail "AC4: expected {\"error\":\"jev failed\"}, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 99 ]]; then
  ac_fail "AC4: exhausted retries debited (now $(balance_of "$FP_A"))"
fi
if [[ "$(invocations)" != 3 ]]; then
  ac_fail "AC4: expected 3 attempts (retries exhausted), got $(invocations)"
fi
stderr_is "jev fp=$FP_A pack=scope model=jev-request-9.9.9 status=429"
ac_log "AC4: 429,429,429 -> retries exhausted, jev failed, no debit"

# ── AC5. 529,529,200 with answers -> success on attempt 3, one debit ──────────
rm -f "$STUB_INVOKED_FILE" "$STUB_BODY_FILE" "$STUB_URL_FILE"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" $'529\n529\n200' "$ANSWERS_MODEL"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC5: 529,529,200 should succeed (rc=$RC, out=$OUT, err=$ERR)"
fi
if [[ "$OUT" != "$ANSWERS_MODEL" ]]; then
  ac_fail "AC5: expected the 200 answers body on stdout, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 98 ]]; then
  ac_fail "AC5: expected one debit (100->99->98), now $(balance_of "$FP_A")"
fi
if [[ "$(invocations)" != 3 ]]; then
  ac_fail "AC5: expected 3 attempts for 529,529,200, got $(invocations)"
fi
stderr_is "jev fp=$FP_A pack=scope model=jev-1.13.0 status=200"
ac_log "AC5: 529,529,200 -> success on attempt 3 (529 retried like 429)"

# ── AC6. 200 with answers but no .model -> debit, log falls back to request ──
rm -f "$STUB_INVOKED_FILE" "$STUB_BODY_FILE" "$STUB_URL_FILE"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" "200" "$ANSWERS_NOMODEL"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC6: 200+answers(no .model) should succeed (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != "$ANSWERS_NOMODEL" ]]; then
  ac_fail "AC6: expected the 200 answers body on stdout, got: $OUT"
fi
if [[ "$(balance_of "$FP_A")" != 97 ]]; then
  ac_fail "AC6: expected one debit (100->99->98->97), now $(balance_of "$FP_A")"
fi
if [[ "$(invocations)" != 1 ]]; then
  ac_fail "AC6: expected 1 attempt (200 not retried), got $(invocations)"
fi
# No .model in the body -> log uses the request model (jev-request-9.9.9).
stderr_is "jev fp=$FP_A pack=scope model=jev-request-9.9.9 status=200"
ac_log "AC6: 200+answers(no .model) -> debit, log falls back to request model"

ac_pass