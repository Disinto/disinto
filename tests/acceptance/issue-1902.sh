#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1902.sh
#
# Issue #1902: the re-review loop must apply pr_author_allowed. A sid in
# PHASE:awaiting_changes whose head SHA moved is not handed to review-pr.sh
# when the PR author is not this reviewer's. The sid is left in place.
#
# Hermetic: no network, no forge, no agent. review-poll.sh is copied next to
# a review-pr.sh stub (it invokes "${SCRIPT_DIR}/review-pr.sh") and lib/ is
# symlinked so env.sh's FACTORY_ROOT stays in the temp tree. curl and
# ci_required_passed are stubs.
#
# Acceptance: `bash tests/acceptance/issue-1902.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp
ac_assert_file "$REPO_ROOT/review/review-poll.sh" "review/review-poll.sh is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-1902.XXXXXX")"
PROJECT="iss1902${RANDOM}"
PR_NUM=1902
OLD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NEW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SID="/tmp/review-session-${PROJECT}-${PR_NUM}.sid"
PHASE="/tmp/review-session-${PROJECT}-${PR_NUM}.phase"
CALLS="${WORK}/review-pr.calls"
CURL_LOG="${WORK}/curl.log"
STDOUT="${WORK}/poll.stdout"
STDERR="${WORK}/poll.stderr"
FAKE_HOME="${WORK}/home"
POLL="${WORK}/review/review-poll.sh"
LOGFILE="${WORK}/review/review-poll.log"

cleanup() {
  rm -f "$SID" "$PHASE"
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "${FAKE_HOME}/.local/bin" "${WORK}/review" "${WORK}/state"
ln -s "$REPO_ROOT/lib" "${WORK}/lib"
cp "$REPO_ROOT/review/review-poll.sh" "$POLL"
touch "${WORK}/state/.reviewer-active"

# ci_required_passed is defined when review-poll sources lib/ci-helpers.sh.
# A DEBUG trap installed from BASH_ENV replaces it once that definition exists.
cat > "${WORK}/ci-stub.env" << 'EOF'
_issue_1902_ci_stub() {
  if declare -F ci_required_passed >/dev/null 2>&1; then
    ci_required_passed() { return 0; }
    trap - DEBUG
  fi
  return 0
}
trap _issue_1902_ci_stub DEBUG
EOF

cat > "${FAKE_HOME}/.local/bin/curl" << 'EOF'
#!/usr/bin/env bash
# Hermetic forge stand-in. The last argument is the URL review-poll passes.
set -euo pipefail
url="${*: -1}"
printf '%s\n' "$url" >> "${AC_CURL_LOG:?}"
author="${AC_PR_AUTHOR:?}"
sha="${AC_NEW_SHA:?}"
case "$url" in
  *'/pulls?state=open'*)
    jq -n --arg author "$author" --arg sha "$sha" \
      '[{number:1902,head:{sha:$sha,ref:"fix/issue-1902"},base:{ref:"main"},draft:false,title:"fix author filter",user:{login:$author}}]'
    ;;
  *'/pulls/1902/reviews')
    jq -n --arg sha "$sha" '[{commit_id:$sha,state:"APPROVED"}]'
    ;;
  *'/pulls/1902')
    jq -n --arg author "$author" --arg sha "$sha" \
      '{state:"open",head:{sha:$sha},user:{login:$author}}'
    ;;
  *)
    exit 22
    ;;
esac
EOF
chmod +x "${FAKE_HOME}/.local/bin/curl"

cat > "${WORK}/review/review-pr.sh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${AC_REVIEW_PR_CALLS:?}"
exit 0
EOF
chmod +x "${WORK}/review/review-pr.sh"

# run_poll AUTHOR — one poll against a fresh awaiting_changes sid whose head moved.
# Prints nothing. Leaves the poll log, curl log, and review-pr call file in WORK.
run_poll() {
  local author="$1"
  : > "$CALLS"
  : > "$CURL_LOG"
  rm -f "$LOGFILE" "$STDOUT" "$STDERR"
  printf 'sid\n' > "$SID"
  printf 'PHASE:awaiting_changes\nSHA:%s\n' "$OLD_SHA" > "$PHASE"
  # Touch so the 4h idle cleanup does not remove the sid before re-review.
  touch "$SID" "$PHASE"

  # Drop factory env that would point this poll at a live forge or a real
  # project name (the sid glob is /tmp/review-session-$PROJECT_NAME-*.sid).
  env -u DISINTO_CONTAINER -u PROJECT_TOML -u FORGE_TOKEN_OVERRIDE \
    -u REVIEW_SKIP_AUTHORS \
    HOME="$FAKE_HOME" \
    USER="${USER:-agent}" \
    BASH_ENV="${WORK}/ci-stub.env" \
    PROJECT_NAME="$PROJECT" \
    PRIMARY_BRANCH=main \
    REVIEW_ONLY_AUTHORS="dev-grok-bot" \
    FORGE_TOKEN=test-token \
    FORGE_URL="http://127.0.0.1:9" \
    FORGE_REPO="example/disinto" \
    AC_PR_AUTHOR="$author" \
    AC_NEW_SHA="$NEW_SHA" \
    AC_CURL_LOG="$CURL_LOG" \
    AC_REVIEW_PR_CALLS="$CALLS" \
    bash "$POLL" >"$STDOUT" 2>"$STDERR"
}

call_count() {
  if [ -s "$CALLS" ]; then
    wc -l < "$CALLS" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

dump_on_fail() {
  ac_log "poll stdout: $(cat "$STDOUT" 2>/dev/null || true)"
  ac_log "poll stderr: $(cat "$STDERR" 2>/dev/null || true)"
  ac_log "poll log: $(cat "$LOGFILE" 2>/dev/null || true)"
  ac_log "curl log: $(cat "$CURL_LOG" 2>/dev/null || true)"
}

# ── AC1: author this reviewer does not handle ───────────────────────────────
ac_log "AC1: REVIEW_ONLY_AUTHORS=dev-grok-bot, author dev-bot, no re-review"
if ! run_poll dev-bot; then
  dump_on_fail
  ac_fail "review-poll.sh exited non-zero for author dev-bot"
fi
ac_assert_eq "$(call_count)" "0" \
  "review-pr.sh must not be called for author dev-bot (calls: $(cat "$CALLS" 2>/dev/null || true))"
grep -F "re-review: author dev-bot is not for this reviewer, skip" "$LOGFILE" >/dev/null \
  || { dump_on_fail; ac_fail "log must say the author is not for this reviewer, skip"; }
[ -f "$SID" ] || ac_fail "skipped sid must be left in place"
ac_log "AC1 OK"

# ── AC2: author this reviewer handles ───────────────────────────────────────
ac_log "AC2: same sid, author dev-grok-bot, review-pr.sh called once"
if ! run_poll dev-grok-bot; then
  dump_on_fail
  ac_fail "review-poll.sh exited non-zero for author dev-grok-bot"
fi
ac_assert_eq "$(call_count)" "1" \
  "review-pr.sh must be called once for author dev-grok-bot (got $(call_count))"
if grep -F "is not for this reviewer, skip" "$LOGFILE" >/dev/null 2>&1; then
  dump_on_fail
  ac_fail "allowed author must not be skipped"
fi
ac_log "AC2 OK"

ac_pass "issue #1902: re-review skips PRs whose author this reviewer does not handle"
