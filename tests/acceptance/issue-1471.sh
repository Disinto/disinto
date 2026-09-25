#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1471.sh
#
# Issue #1471: feat(edge): jev verb runs a named pack and debits one credit
#
# Exercises verbs/jev.sh against a throwaway $ACCOUNTS_FILE in a mktemp dir.
# The TypeSafe call is intercepted by a fake `curl` dropped at the front of
# PATH (so the verb's request never reaches api.typesafe.ai or any live host).
# The fake records the POST body, the Bearer auth it saw, and the URL it
# got pointed at, and can be told to return a chosen HTTP status (default 200
# on the /v1/systemone endpoint) — so the 200 and reject branches are both
# exercised locally.
#
#   AC1  A *pending* key is rejected ("not approved") and not debited; the
#        socket is never opened.
#   AC2  An *approved* key with 0 credits is rejected ("no credits") and not
#        debited; the socket is never opened.
#   AC3  With TYPESAFE_API_KEY unset, jev is rejected ("jev not configured")
#        before any socket is opened and not debited.
#   AC4  A configured 200 response: rc 0, stdout is the response body, the
#        account is debited *exactly* one credit, the POSTed .questions
#        come from the pack file (the sole source — never stdin/hardcoded),
#        .model is the default jev-1.13.0, .state round-trips stdin, the
#        Bearer key was sent, the request URL is the local stub (not
#        api.typesafe.ai), and the one-line stderr log carries only
#        fp/pack/model/status (no state, no key).
#   AC5  A path-ish pack id ("../accounts" and friends) is rejected ("unknown
#        pack") pre-socket (the ^[a-z][a-z0-9-]*$ gate stops traversal) and
#        not debited.
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
ACCOUNTS_LIB="$REPO_ROOT/tools/edge-control/lib/accounts.sh"
SCOPE_PACK="$REPO_ROOT/tools/edge-control/packs/scope.json"

ac_assert_file "$JEV" "verbs/jev.sh is missing"
ac_assert_file "$ACCOUNTS_LIB" "lib/accounts.sh is missing"
ac_assert_file "$SCOPE_PACK" "packs/scope.json is missing"

# The pack must be exactly the questions *map* the issue names: three Nouls
# (one per key), each with `type == "noul"` and its named instruction — a
# string array or any other shape is no longer valid (issue #1535).
jq -e '
  (.questions
    | (type == "object")
      and (keys == ["one_behavior", "one_concept", "one_repo"]))
  and (.questions.one_concept
       == {type: "noul", instructions: "The proposal is one concept."})
  and (.questions.one_repo
       == {type: "noul", instructions: "The proposal names one repository."})
  and (.questions.one_behavior
       == {type: "noul", instructions: "The proposal names one observable behavior."})' \
   "$SCOPE_PACK" >/dev/null 2>&1 \
  || ac_fail "scope.json questions noul map wrong: $(jq -c '.' "$SCOPE_PACK")"

# ── Fixtures: throwaway ledger ───────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"

# seed_row emits pending rows, but jev requires status == "approved" — flip a
# specific row to "approved" in the throwaway ledger.
approve_row() {
  local fp="$1"
  jq --arg fp "$fp" '.accounts[$fp].status = "approved"' "$ACCOUNTS_FILE" \
    > "${ACCOUNTS_FILE}.tmp" || ac_fail "cannot flip $fp to approved"
  mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"
}

# Two extra fixture fingerprints beyond the helpers' FP_A/FP_B/FP_ADMIN, so
# each acceptance criterion has its own row (unambiguous "not debited" checks).
FP_C="SHA256:$(printf 'C%.0s' {1..43})"
FP_D="SHA256:$(printf 'D%.0s' {1..43})"
FP_E="SHA256:$(printf 'E%.0s' {1..43})"
for fp in "$FP_C" "$FP_D" "$FP_E"; do
  [[ "$fp" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
    || ac_fail "test fixture fingerprint is malformed: $fp"
done

# seed_row + FP_A/FP_B/FP_ADMIN come from tests/lib/acceptance-helpers.sh.
# jev requires status == "approved", but seed_row emits pending rows — so
# flip the rows the success/HTTP ACs exercise to "approved" below.
seed_row "$FP_A" "acme"    "false" 1
seed_row "$FP_B" "bravo"   "false" 0
seed_row "$FP_C" "charlie" "false" 1
seed_row "$FP_D" "delta"   "false" 1
seed_row "$FP_E" "echo"    "false" 1
approve_row "$FP_B"
approve_row "$FP_C"
approve_row "$FP_D"
approve_row "$FP_E"

# ── TypeSafe stub: a fake `curl` at the front of PATH ────────────────────────
# Captures the POST body (--data), the Bearer auth it saw, and the URL it got
# pointed at; touches STUB_INVOKED_FILE as proof it ran. STUB_HTTP_CODE
# overrides the returned status (default 200 on /v1/systemone, 404 elsewhere);
# STUB_BODY overrides the returned body. It always exits 0 (real curl does on
# HTTP errors without -f), so the verb classifies by code, not process rc.
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB_CURL'
#!/usr/bin/env bash
set -u

# Proof that this stub was invoked at all (reject paths must NOT reach it).
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
    -d)        i=$((i + 1)); body="${args[i]}" ;;
    -d=*):     body="${arg#-d=}" ;;
    --data)    i=$((i + 1)); body="${args[i]}" ;;
    --data=*): body="${arg#--data=}" ;;
    --header)
      i=$((i + 1))
      hdr="${args[i]}"
      if [[ "$hdr" == "Authorization: Bearer "* ]]; then
        auth="${hdr#Authorization: Bearer }"
      fi
      ;;
    -w) ;;
    -s) ;;
    --request) i=$((i + 1)) ;;
    *)
      if [[ "$arg" == "http://"* || "$arg" == "https://"* || "$arg" == "localhost:"* ]]; then
        [[ -z "$url" ]] && url="$arg"
      fi
      # Single-arg catch-all: the trailing i=$((i + 1)) below advances past it.
      ;;
  esac
  i=$((i + 1))
done

[[ -n "${STUB_BODY_FILE:-}" ]]  && printf '%s' "$body" > "$STUB_BODY_FILE"
[[ -n "${STUB_AUTH_FILE:-}" ]] && printf '%s' "$auth" > "$STUB_AUTH_FILE"
[[ -n "${STUB_URL_FILE:-}" ]]  && printf '%s' "$url"  > "$STUB_URL_FILE"

# HTTP code: explicit override, else 200 on the systemone endpoint.
case "$url" in
  *"/v1/systemone") code="${STUB_HTTP_CODE:-200}" ;;
  *)               code="${STUB_HTTP_CODE:-404}" ;;
esac

if [[ -n "${STUB_BODY:-}" ]]; then
  resp_body="$STUB_BODY"
elif [[ "$code" =~ ^2[0-9]{2}$ ]]; then
  resp_body="$(printf '{"status":"ok"}')"
else
  resp_body=""
fi

# -w $'\n%{http_code}' => body, newline, code.
printf '%s\n%s\n' "$resp_body" "$code"
STUB_CURL
chmod +x "$STUB_DIR/curl"

# ── Env: fake TypeSafe API + capture files ───────────────────────────────────
TYPESAFE_API_URL="http://127.0.0.1:9999"   # local stub; never api.typesafe.ai
API_KEY="stub-jev-key-abcdef"
STUB_BODY_FILE="$TMP_DIR/curl_body.json"
STUB_AUTH_FILE="$TMP_DIR/curl_auth.txt"
STUB_URL_FILE="$TMP_DIR/curl_url.txt"
STUB_INVOKED="$TMP_DIR/stub_invoked"
export STUB_BODY_FILE STUB_AUTH_FILE STUB_URL_FILE STUB_INVOKED
# EDGE_APPLY and the key are left unset by default; run_jev manages the key per
# call so a parent env value can never leak into the "unset key" AC.
unset EDGE_APPLY 2>/dev/null || true
unset TYPESAFE_API_KEY 2>/dev/null || true

# ── Run jev exactly as the dispatcher would (fake curl on PATH) ──────────────
# $1=fp  $2=pack_id  $3=stdin-state  $4=api_key ("" = unset)  $5=http_code
# stdout -> OUT, stderr -> ERR, exit status -> RC.
run_jev() {
  local fp="$1" pack_id="$2" state="$3" api_key="${4:-}" http_code="${5:-}"
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
      STUB_HTTP_CODE="$http_code" \
        STUB_BODY_FILE="$STUB_BODY_FILE" STUB_AUTH_FILE="$STUB_AUTH_FILE" \
        STUB_URL_FILE="$STUB_URL_FILE" \
        STUB_INVOKED_FILE="$STUB_INVOKED" \
        ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$fp" \
        TYPESAFE_API_URL="$TYPESAFE_API_URL" \
        PATH="$STUB_DIR:$PATH" \
        bash "$JEV" "$pack_id" 2>"$errfile"
  )" || RC=$?
  ERR="$(cat "$errfile")"
}

# The row's credits ("" -> empty).
balance_of() {
  jq -r --arg fp "$1" '(.accounts // {})[$fp].credits // ""' "$ACCOUNTS_FILE"
}

STATE="one concept: one repo: one observable behavior"

# ── AC1. a pending key is rejected, not debited, no socket ────────────────────
rm -f "$STUB_INVOKED"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY"
if [ "$RC" -ne 1 ]; then
  ac_fail "AC1: pending (FP_A) jev should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"not approved"}' ]]; then
  ac_fail "AC1: expected {\"error\":\"not approved\"}, got: $OUT"
fi
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC1: stub invoked on a rejected (pending) call — no socket should open"
fi
if [[ "$(balance_of "$FP_A")" != 1 ]]; then
  ac_fail "AC1: rejected pending call debited FP_A (now $(balance_of "$FP_A"))"
fi
ac_log "AC1: pending key -> not approved, not debited, no socket"

# ── AC2. an approved key with 0 credits is rejected, not debited, no socket ─
rm -f "$STUB_INVOKED"
run_jev "$FP_B" "scope" "$STATE" "$API_KEY"
if [ "$RC" -ne 1 ]; then
  ac_fail "AC2: approved 0-credit (FP_B) jev should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"no credits"}' ]]; then
  ac_fail "AC2: expected {\"error\":\"no credits\"}, got: $OUT"
fi
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC2: stub invoked on a 0-credit rejected call — no socket should open"
fi
if [[ "$(balance_of "$FP_B")" != 0 ]]; then
  ac_fail "AC2: 0-credit rejected call debited FP_B (now $(balance_of "$FP_B"))"
fi
ac_log "AC2: approved 0-credit key -> no credits, not debited, no socket"

# ── AC3. unset API key -> jev not configured, no socket, not debited ─────────
rm -f "$STUB_INVOKED"
run_jev "$FP_C" "scope" "$STATE" ""
if [ "$RC" -ne 1 ]; then
  ac_fail "AC3: unset API key (FP_C) jev should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"jev not configured"}' ]]; then
  ac_fail "AC3: expected {\"error\":\"jev not configured\"}, got: $OUT"
fi
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC3: stub invoked with an unset key — no socket should open"
fi
if [[ "$(balance_of "$FP_C")" != 1 ]]; then
  ac_fail "AC3: unset-key rejected call debited FP_C (now $(balance_of "$FP_C"))"
fi
ac_log "AC3: unset API key -> jev not configured, not debited, no socket"

# ── AC4. configured 200: rc 0, body echoed, exactly one credit, questions ────
#        from the pack, model/state round-trip, key sent, local URL, clean log
rm -f "$STUB_INVOKED" "$STUB_BODY_FILE" "$STUB_AUTH_FILE" "$STUB_URL_FILE"
run_jev "$FP_D" "scope" "$STATE" "$API_KEY" "200"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC4: configured 200 jev should succeed (rc=$RC, out=$OUT)"
fi
if [ ! -f "$STUB_INVOKED" ]; then
  ac_fail "AC4: stub never invoked on the configured path"
fi
if [[ "$OUT" != '{"status":"ok"}' ]]; then
  ac_fail "AC4: expected {\"status\":\"ok\"}, got: $OUT"
fi
if [[ "$(balance_of "$FP_D")" != 0 ]]; then
  ac_fail "AC4: 200 response debited the wrong amount (now $(balance_of "$FP_D"))"
fi
if [[ ! -f "$STUB_BODY_FILE" ]]; then
  ac_fail "AC4: POST body not captured: $(cat "$STUB_BODY_FILE" 2>/dev/null)"
fi
# The POSTed .questions came from the pack file (the sole source) — never
# stdin, never hardcoded.
if ! [[ "$(jq -c '.questions' "$STUB_BODY_FILE")" \
      == "$(jq -c '.questions' "$SCOPE_PACK")" ]]; then
  ac_fail "AC4: POST questions differ from the pack file (got $(jq -c '.questions' "$STUB_BODY_FILE"), want $(jq -c '.questions' "$SCOPE_PACK"))"
fi
# .model is the default; .state round-trips stdin exactly.
if ! jq -e --arg m "jev-1.13.0" --arg s "$STATE" \
    '.model == $m and .state == $s' "$STUB_BODY_FILE" >/dev/null 2>&1; then
  ac_fail "AC4: POST model/state wrong: $(cat "$STUB_BODY_FILE")"
fi
# The Bearer key was sent (and is the configured stub key).
if [[ "$(cat "$STUB_AUTH_FILE")" != "$API_KEY" ]]; then
  ac_fail "AC4: Bearer auth wrong: $(cat "$STUB_AUTH_FILE")"
fi
# The request URL is the local stub — never api.typesafe.ai.
url_sent="$(cat "$STUB_URL_FILE")"
if [[ "$url_sent" != "$TYPESAFE_API_URL/v1/systemone" ]]; then
  ac_fail "AC4: request URL wrong (not the local stub): $url_sent"
fi
if [[ "$url_sent" == *"api.typesafe.ai"* ]]; then
  ac_fail "AC4: request reached api.typesafe.ai: $url_sent"
fi
# One-line stderr log: only fp/pack/model/status. No state, no key, anywhere
# (stdout, stderr, or log).
if [[ "$ERR" != "jev fp=$FP_D pack=scope model=jev-1.13.0 status=200" ]]; then
  ac_fail "AC4: stderr log line wrong: $ERR"
fi
if [[ "$OUT" == *"$API_KEY"* ]] || [[ "$ERR" == *"$API_KEY"* ]]; then
  ac_fail "AC4: API key leaked into stdout/stderr"
fi
if [[ "$ERR" == *"$STATE"* ]]; then
  ac_fail "AC4: stdin state leaked into the stderr log"
fi
ac_log "AC4: 200 -> body echoed, exactly one credit debited, questions from pack"

# ── AC5. a path-ish pack id is rejected pre-socket, not debited ──────────────
rm -f "$STUB_INVOKED"
run_jev "$FP_E" "../accounts" "$STATE" "$API_KEY"
if [ "$RC" -ne 1 ]; then
  ac_fail "AC5: pack id '../accounts' (FP_E) jev should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"unknown pack"}' ]]; then
  ac_fail "AC5: expected {\"error\":\"unknown pack\"} for '../accounts', got: $OUT"
fi
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC5: stub invoked for '../accounts' — the path must be rejected pre-socket"
fi
# A few more malformed ids: all rejected before any socket (regex gate).
for bad in UPPER "foo/bar" "1bad" ".."; do
  run_jev "$FP_E" "$bad" "$STATE" "$API_KEY"
  if [ "$RC" -ne 1 ]; then
    ac_fail "AC5: malformed pack id '$bad' should fail (rc=$RC, out=$OUT)"
  fi
  if [[ "$OUT" != '{"error":"unknown pack"}' ]]; then
    ac_fail "AC5: expected {\"error\":\"unknown pack\"} for '$bad', got: $OUT"
  fi
done
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC5: stub invoked for a malformed pack id (should be regex-rejected)"
fi
if [[ "$(balance_of "$FP_E")" != 1 ]]; then
  ac_fail "AC5: malformed-id rejected calls debited FP_E (now $(balance_of "$FP_E"))"
fi
ac_log "AC5: path-ish / malformed pack ids -> unknown pack, not debited, no socket"

ac_pass