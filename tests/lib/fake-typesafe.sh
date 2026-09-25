#!/usr/bin/env bash
# =============================================================================
# tests/lib/fake-typesafe.sh — shared TypeSafe stub for acceptance tests
#
# Sourced by tests/acceptance/issue-<N>.sh that exercise verbs/jev.sh. The
# TypeSafe API (POST /v1/systemone) is jev's only external call, so a hermetic
# test must intercept it. This installs a fake `curl` at $TMP_DIR/stub/curl
# (dropped at the front of PATH when jev runs, so the verb's request never
# reaches api.typesafe.ai or any live host). The fake records the POST body,
# the Bearer auth it saw, and the URL it got pointed at, and can be told to
# return a chosen HTTP status (STUB_HTTP_CODE; default 200 on /v1/systemone,
# 404 elsewhere). STUB_BODY overrides the returned body. It always exits 0
# (real curl does on HTTP errors without -f), so the verb classifies by code,
# not process rc.
#
# Must be sourced AFTER TMP_DIR, JEV, and ACCOUNTS_FILE are defined. Provides:
#   STUB_DIR, TYPESAFE_API_URL, API_KEY,
#   STUB_BODY_FILE, STUB_AUTH_FILE, STUB_URL_FILE, STUB_INVOKED
#   run_jev(fp, pack_id, state, api_key, http_code) -> sets OUT, RC, ERR
#   balance_of(fp) -> the row's credits ("" -> empty)
#
# Conventions:
#   - read-only against the repo tree; all temp output lives under $TMP_DIR.
#   - does not depend on acceptance-helpers.sh; the ACs that assert on ERR, OUT
#     and the balances are in the sourcing tests.
# =============================================================================

# Idempotent guard.
if [ -n "${FAKE_TYPESAFE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
FAKE_TYPESAFE_LOADED=1

# ── Install the stub: a fake `curl` at $TMP_DIR/stub/curl ────────────────────
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
export API_KEY="stub-jev-key-abcdef"       # consumed by the tests' ACs
# local stub; never api.typesafe.ai
TYPESAFE_API_URL="http://127.0.0.1:9999"
STUB_BODY_FILE="$TMP_DIR/curl_body.json"
STUB_AUTH_FILE="$TMP_DIR/curl_auth.txt"
STUB_URL_FILE="$TMP_DIR/curl_url.txt"
STUB_INVOKED="$TMP_DIR/stub_invoked"
export STUB_BODY_FILE STUB_AUTH_FILE STUB_URL_FILE STUB_INVOKED
# EDGE_APPLY and the key are left unset by default; run_jev manages the key per
# call so a parent env value can never leak into the run.
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
  # OUT/RC/ERR are the calling test's globals (the ACs read them); they are set
  # here and consumed externally, so export to mark intent.
  export RC OUT ERR
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
