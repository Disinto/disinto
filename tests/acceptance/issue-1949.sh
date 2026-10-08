#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1949.sh
#
# Issue #1949: bin/notify-owner.sh TEXT sends the owner a Telegram message.
# Host-side only, called by the healer (bin/healer.sh) under the AD-006
# exception (#1970). Never sourced from lib/ or an agent. A missing channel
# never blocks the caller.
#
#   * TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID set, reply {"ok":true}:
#     exit 0. The curl stub saw a URL ending in /sendMessage, chat_id=<id>,
#     and the text.
#   * Either variable empty: exit 0, print "notify-owner: not configured",
#     and curl is not called.
#   * Reply {"ok":false,"description":"Unauthorized"}: exit 1, stderr
#     contains Unauthorized but not the token.
#   * A 5000-character text reaches curl as at most 4000 characters.
#   * git grep -n notify-owner -- lib prints nothing.
#
# Hermetic: a curl stub on PATH records its arguments and prints a canned
# reply. No network.
#
# Acceptance: `bash tests/acceptance/issue-1949.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk git
NOTIFY="$REPO_ROOT/bin/notify-owner.sh"
ac_assert_file "$NOTIFY" "bin/notify-owner.sh is missing"
[ -x "$NOTIFY" ] || ac_fail "bin/notify-owner.sh must be executable"

# Header: host-side only, healer call, AD-006 exception. Not a library.
grep -qF 'host-side only' "$NOTIFY" \
  || ac_fail "header must say host-side only"
grep -qF 'bin/healer.sh' "$NOTIFY" \
  || ac_fail "header must say it is called by bin/healer.sh"
grep -qF 'AD-006' "$NOTIFY" \
  || ac_fail "header must name the AD-006 exception"
grep -qF '#1970' "$NOTIFY" \
  || ac_fail "header must cite the AD-006 exception issue (#1970)"
grep -qF 'Never source it from lib/ or an agent' "$NOTIFY" \
  || ac_fail "header must say never source it from lib/ or an agent"
# The script itself must not enable xtrace. set +x (disable) is required
# so bash -x cannot print the token; set -x is forbidden.
if grep -nE '(^|[[:space:]])set[[:space:]]+-[^#[:space:]]*x' "$NOTIFY" | grep -vE '^[^:]+:[[:space:]]*#'; then
  ac_fail "bin/notify-owner.sh must not enable xtrace (no set -x)"
fi
grep -qE '(^|[[:space:]])set[[:space:]]+\+x' "$NOTIFY" \
  || ac_fail "bin/notify-owner.sh must disable xtrace before the token is expanded"

ac_log "lib/ must not mention notify-owner"
lib_hits="$(git -C "$REPO_ROOT" grep -n notify-owner -- lib || true)"
[ -z "$lib_hits" ] || ac_fail "git grep -n notify-owner -- lib must print nothing (got: ${lib_hits})"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
CURL_LOG="$WORK/curl.log"
: >"$CURL_LOG"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Record each argument on its own line, then print the canned reply.
if [ -z "${NOTIFY_STUB_ARGS:-}" ]; then
  printf 'curl stub: NOTIFY_STUB_ARGS unset\n' >&2
  exit 97
fi
printf '%s\n' "$@" >> "$NOTIFY_STUB_ARGS"
printf '%s' "${NOTIFY_STUB_REPLY-}"
exit "${NOTIFY_STUB_RC:-0}"
STUB
chmod +x "$STUB_BIN/curl"

export PATH="$STUB_BIN:$PATH"
export NOTIFY_STUB_ARGS="$CURL_LOG"

TOKEN="999001:SUPERSECRETTOKEN"
CHAT_ID="424242"

# run_notify TEXT — execute bin/notify-owner.sh, capture rc/stdout/stderr.
# Caller exports TELEGRAM_* and NOTIFY_STUB_*.
run_notify() {
  local text="$1"
  RUN_RC=0
  RUN_OUT="$WORK/out"
  RUN_ERR="$WORK/err"
  "$NOTIFY" "$text" >"$RUN_OUT" 2>"$RUN_ERR" || RUN_RC=$?
}

reset_log() {
  : >"$CURL_LOG"
  unset NOTIFY_STUB_REPLY NOTIFY_STUB_RC
}

# ── AC1: configured, ok:true ────────────────────────────────────────────────
ac_log "AC1: token and chat id set, ok:true exits 0 and curl saw the send"
reset_log
export TELEGRAM_BOT_TOKEN="$TOKEN"
export TELEGRAM_CHAT_ID="$CHAT_ID"
export NOTIFY_STUB_REPLY='{"ok":true}'
export NOTIFY_STUB_RC=0
run_notify "ping from healer"
ac_assert_eq "$RUN_RC" "0" "ok:true must exit 0 (got $RUN_RC)"
grep -qE '/sendMessage$' "$CURL_LOG" \
  || ac_fail "curl did not see a URL ending in /sendMessage (log: $(tr '\n' ' ' < "$CURL_LOG"))"
grep -qxF "chat_id=${CHAT_ID}" "$CURL_LOG" \
  || ac_fail "curl did not see chat_id=${CHAT_ID}"
grep -qxF "text=ping from healer" "$CURL_LOG" \
  || ac_fail "curl did not see the text"
grep -qxF "https://api.telegram.org/bot${TOKEN}/sendMessage" "$CURL_LOG" \
  || ac_fail "curl did not see the sendMessage URL"
grep -qxF -- "-m" "$CURL_LOG" \
  || ac_fail "curl must be invoked with -m"
grep -qxF "15" "$CURL_LOG" \
  || ac_fail "curl must be invoked with -m 15"
grep -qxF "disable_web_page_preview=true" "$CURL_LOG" \
  || ac_fail "curl must disable web page preview"
if grep -qF "$TOKEN" "$RUN_ERR" || grep -qF "$TOKEN" "$RUN_OUT"; then
  ac_fail "token leaked on the success path"
fi
[ ! -s "$RUN_OUT" ] || ac_fail "success path must not print the reply"

# ── AC2: either variable empty ──────────────────────────────────────────────
ac_log "AC2: empty token exits 0, prints not configured, does not call curl"
reset_log
export TELEGRAM_BOT_TOKEN=""
export TELEGRAM_CHAT_ID="$CHAT_ID"
run_notify "should not send"
ac_assert_eq "$RUN_RC" "0" "empty token must exit 0 (got $RUN_RC)"
grep -qxF "notify-owner: not configured" "$RUN_ERR" \
  || ac_fail "empty token must print 'notify-owner: not configured' (stderr: $(cat "$RUN_ERR"))"
[ ! -s "$CURL_LOG" ] || ac_fail "empty token must not call curl"

ac_log "AC2b: empty chat id exits 0, prints not configured, does not call curl"
reset_log
export TELEGRAM_BOT_TOKEN="$TOKEN"
export TELEGRAM_CHAT_ID=""
run_notify "should not send"
ac_assert_eq "$RUN_RC" "0" "empty chat id must exit 0 (got $RUN_RC)"
grep -qxF "notify-owner: not configured" "$RUN_ERR" \
  || ac_fail "empty chat id must print 'notify-owner: not configured' (stderr: $(cat "$RUN_ERR"))"
[ ! -s "$CURL_LOG" ] || ac_fail "empty chat id must not call curl"
if grep -qF "$TOKEN" "$RUN_ERR"; then
  ac_fail "token leaked when the channel is not configured"
fi

ac_log "AC2c: unset token exits 0 and does not call curl"
reset_log
unset TELEGRAM_BOT_TOKEN
export TELEGRAM_CHAT_ID="$CHAT_ID"
run_notify "should not send"
ac_assert_eq "$RUN_RC" "0" "unset token must exit 0 (got $RUN_RC)"
grep -qxF "notify-owner: not configured" "$RUN_ERR" \
  || ac_fail "unset token must print 'notify-owner: not configured'"
[ ! -s "$CURL_LOG" ] || ac_fail "unset token must not call curl"

# ── AC3: ok:false with a description ────────────────────────────────────────
ac_log "AC3: Unauthorized reply exits 1; stderr has the description, not the token"
reset_log
export TELEGRAM_BOT_TOKEN="$TOKEN"
export TELEGRAM_CHAT_ID="$CHAT_ID"
export NOTIFY_STUB_REPLY='{"ok":false,"description":"Unauthorized"}'
export NOTIFY_STUB_RC=0
run_notify "a fault the healer could not fix"
ac_assert_eq "$RUN_RC" "1" "ok:false must exit 1 (got $RUN_RC)"
grep -qF "Unauthorized" "$RUN_ERR" \
  || ac_fail "stderr must contain Unauthorized (stderr: $(cat "$RUN_ERR"))"
grep -qxF "notify-owner: telegram send failed: Unauthorized" "$RUN_ERR" \
  || ac_fail "stderr must carry only the reply description (stderr: $(cat "$RUN_ERR"))"
if grep -qF "$TOKEN" "$RUN_ERR" || grep -qF "$TOKEN" "$RUN_OUT"; then
  ac_fail "token leaked in the failure message"
fi

# A description that echoes the token must still not print it.
ac_log "AC3b: a description that echoes the token is redacted"
reset_log
export NOTIFY_STUB_REPLY="{\"ok\":false,\"description\":\"bad ${TOKEN} request\"}"
export NOTIFY_STUB_RC=0
run_notify "echoed token"
ac_assert_eq "$RUN_RC" "1" "echoed-token failure must exit 1 (got $RUN_RC)"
if grep -qF "$TOKEN" "$RUN_ERR" || grep -qF "$TOKEN" "$RUN_OUT"; then
  ac_fail "token leaked from a description that echoed it"
fi
grep -qF "notify-owner: telegram send failed:" "$RUN_ERR" \
  || ac_fail "redacted failure must still name the telegram send failure"

# curl's own failure, with no description, reports the exit code only.
ac_log "AC3c: curl failure with no body reports the exit code, not the token"
reset_log
export NOTIFY_STUB_REPLY=""
export NOTIFY_STUB_RC=28
run_notify "curl died"
ac_assert_eq "$RUN_RC" "1" "curl failure must exit 1 (got $RUN_RC)"
grep -qxF "notify-owner: telegram send failed: 28" "$RUN_ERR" \
  || ac_fail "curl failure must report the exit code (stderr: $(cat "$RUN_ERR"))"
if grep -qF "$TOKEN" "$RUN_ERR" || grep -qF "$TOKEN" "$RUN_OUT"; then
  ac_fail "token leaked on the curl-failure path"
fi

# ── AC4: truncate to 4000 characters ────────────────────────────────────────
ac_log "AC4: a 5000-character text reaches curl as at most 4000 characters"
reset_log
export TELEGRAM_BOT_TOKEN="$TOKEN"
export TELEGRAM_CHAT_ID="$CHAT_ID"
export NOTIFY_STUB_REPLY='{"ok":true}'
export NOTIFY_STUB_RC=0
LONG="$(awk 'BEGIN{for(i=0;i<5000;i++) printf "B"}')"
ac_assert_eq "${#LONG}" "5000" "fixture text must be 5000 characters"
run_notify "$LONG"
ac_assert_eq "$RUN_RC" "0" "truncated send must still exit 0 on ok:true (got $RUN_RC)"
TEXT_ARG="$(grep '^text=' "$CURL_LOG" || true)"
[ -n "$TEXT_ARG" ] || ac_fail "curl did not see a text= argument"
VAL="${TEXT_ARG#text=}"
if [ "${#VAL}" -gt 4000 ]; then
  ac_fail "text reached curl as ${#VAL} characters, want at most 4000"
fi
ac_assert_eq "${#VAL}" "4000" "text must be truncated to 4000 characters (got ${#VAL})"
ac_assert_eq "$VAL" "${LONG:0:4000}" "truncated text must be the leading 4000 characters"

ac_pass
