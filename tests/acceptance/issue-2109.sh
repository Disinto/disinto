#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2109.sh
#
# Issue #2109: each review poll records its work — reviews due, done and
# failed — as one evidence line written by lib/rollout-evidence.sh (#2106),
# which the rollout tool reads to tell whether the canary reviewer works.
# review-poll.sh counts FAILED alongside REVIEWED, appends one "work" line
# per poll (due = REVIEWED + FAILED), and adds ", <FAILED> failed" to its
# closing log line. A failed append never fails the poll.
#
# Hermetic: no network, no forge, no agent. A copy of review-poll.sh runs
# next to a symlinked lib/ and a review-pr.sh stub whose exit code is set by
# AC_REVIEW_RC; curl and ci_required_passed are stubs. Each AC gets its own
# temp TAPE_DIR, with NOMAD_JOB_NAME=agents-test.
#
# Acceptance:
#   1. review-pr.sh stub exits 1, one PR needing review: the last evidence
#      line is kind work, due 1, done 0, failed 1; the poll exits 0.
#   2. stub exits 0: due 1, done 1, failed 0.
#   3. no open PRs: exactly one work line, due 0.
#   4. TAPE_DIR is a read-only directory: the poll still exits 0.
#   5. tests/acceptance/issue-1902.sh still passes (it sets no TAPE_DIR).
#
# Acceptance: `bash tests/acceptance/issue-2109.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp chmod wc tail

POLL_SRC="$REPO_ROOT/review/review-poll.sh"
ac_assert_file "$POLL_SRC" "review/review-poll.sh is missing"
ac_assert_file "$REPO_ROOT/lib/rollout-evidence.sh" "lib/rollout-evidence.sh is missing"

# ── wiring: the poll sources the evidence lib and calls rollout_evidence_work ─
grep -q 'lib/rollout-evidence\.sh' "$POLL_SRC" \
  || ac_fail "review-poll.sh must source lib/rollout-evidence.sh"
grep -q 'rollout_evidence_work review' "$POLL_SRC" \
  || ac_fail "review-poll.sh must call rollout_evidence_work review"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-2109.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PROJECT="iss2109${RANDOM}"
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
POLL="${WORK}/review/review-poll.sh"
LOGFILE="${WORK}/review/review-poll.log"
CURL_LOG="${WORK}/curl.log"
CALLS="${WORK}/review-pr.calls"
STDOUT="${WORK}/poll.stdout"
STDERR="${WORK}/poll.stderr"
STUB_DIR="${WORK}/fake-home"

mkdir -p "${STUB_DIR}/.local/bin" "${WORK}/review" "${WORK}/state"
ln -s "$REPO_ROOT/lib" "${WORK}/lib"
cp "$POLL_SRC" "$POLL"
touch "${WORK}/state/.reviewer-active"

# A DEBUG trap installed from BASH_ENV swaps ci_required_passed for a green
# stub as soon as lib/ci-helpers.sh (sourced by the poll) defines it.
cat > "${WORK}/ci-stub.env" << 'CIENV'
_ci_green() {
  declare -F ci_required_passed >/dev/null 2>&1 || return 0
  ci_required_passed() { return 0; }
  trap - DEBUG
  return 0
}
trap _ci_green DEBUG
CIENV

cat > "${STUB_DIR}/.local/bin/curl" << 'CURLSTUB'
#!/usr/bin/env bash
# Fake forge API for the poll: the last argument is the URL review-poll passes.
set -euo pipefail
url="${*: -1}"
printf '%s\n' "$url" >> "${AC_CURL_LOG:?}"
sha="${AC_HEAD_SHA:?}"
if [ "${AC_NO_PRS:-}" = "1" ]; then
  case "$url" in
    *'/pulls?state=open'*) echo '[]' ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
case "$url" in
  *'/pulls?state=open'*)
    jq -n --arg sha "$sha" \
      '[{number:2109,head:{sha:$sha,ref:"fix/issue-2109"},base:{ref:"main"},draft:false,title:"evidence",user:{login:"dev-bot"}}]'
    ;;
  *'/pulls/2109/reviews') echo '[]' ;;
  *'/issues/2109/comments') echo '[]' ;;
  *'/pulls/2109')
    jq -n --arg sha "$sha" '{state:"open",head:{sha:$sha},user:{login:"dev-bot"}}'
    ;;
  *) exit 22 ;;
esac
CURLSTUB
chmod +x "${STUB_DIR}/.local/bin/curl"

# review-pr.sh stub: exit code comes from AC_REVIEW_RC; every call is counted.
cat > "${WORK}/review/review-pr.sh" << 'PRSTUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${AC_REVIEW_PR_CALLS:?}"
exit "${AC_REVIEW_RC:-0}"
PRSTUB
chmod +x "${WORK}/review/review-pr.sh"

# run_poll TAPE_DIR REVIEW_RC [NO_PRS=0] — one poll run against a fresh log
# and curl log; evidence lands in $TAPE_DIR/rollout/evidence/agents-test.jsonl.
run_poll() {
  local tape="$1" review_rc="$2" no_prs="${3:-0}"
  : > "$CALLS"
  : > "$CURL_LOG"
  rm -f "$LOGFILE" "$STDOUT" "$STDERR"
  env -u DISINTO_CONTAINER -u PROJECT_TOML -u FORGE_TOKEN_OVERRIDE \
    HOME="$STUB_DIR" \
    USER="${USER:-agent}" \
    BASH_ENV="${WORK}/ci-stub.env" \
    PROJECT_NAME="$PROJECT" \
    PRIMARY_BRANCH=main \
    FORGE_TOKEN=test-token \
    FORGE_URL="http://127.0.0.1:9" \
    FORGE_REPO="example/disinto" \
    TAPE_DIR="$tape" \
    NOMAD_JOB_NAME=agents-test \
    AC_HEAD_SHA="$HEAD_SHA" \
    AC_CURL_LOG="$CURL_LOG" \
    AC_REVIEW_PR_CALLS="$CALLS" \
    AC_REVIEW_RC="$review_rc" \
    AC_NO_PRS="$no_prs" \
    bash "$POLL" >"$STDOUT" 2>"$STDERR"
}

last_evidence_line() {
  tail -n 1 "$1/rollout/evidence/agents-test.jsonl" 2>/dev/null
}

# ── AC1: the review fails — due 1, done 0, failed 1, poll exits 0 ─────────────
ac_log "AC1: review-pr.sh exits 1 -> work line due 1 done 0 failed 1"
T1="${WORK}/tape-ac1"
mkdir -p "$T1"
rc=0
run_poll "$T1" 1 || rc=$?
ac_assert_eq "$rc" "0" "AC1: the poll must exit 0 even when every review fails (got $rc; stderr: $(cat "$STDERR" 2>/dev/null || true))"
ac_assert_eq "$(wc -l < "$CALLS" | tr -d '[:space:]')" "1" \
  "AC1: review-pr.sh must be called once (got $(cat "$CALLS" 2>/dev/null || true))"
line="$(last_evidence_line "$T1")"
ac_assert_jq '.kind == "work" and .due == 1 and .done == 0 and .failed == 1' \
  "$line" "AC1: last evidence line must be work due 1 done 0 failed 1, got: $line"
grep -F ", 1 failed" "$LOGFILE" >/dev/null \
  || { ac_log "poll log: $(cat "$LOGFILE" 2>/dev/null || true)"; ac_fail "AC1: closing log line must say ', 1 failed'"; }
ac_log "AC1 OK"

# ── AC2: the review succeeds — due 1, done 1, failed 0 ────────────────────────
ac_log "AC2: review-pr.sh exits 0 -> work line due 1 done 1 failed 0"
T2="${WORK}/tape-ac2"
mkdir -p "$T2"
rc=0
run_poll "$T2" 0 || rc=$?
ac_assert_eq "$rc" "0" "AC2: the poll must exit 0 (got $rc)"
line="$(last_evidence_line "$T2")"
ac_assert_jq '.kind == "work" and .due == 1 and .done == 1 and .failed == 0' \
  "$line" "AC2: last evidence line must be work due 1 done 1 failed 0, got: $line"
ac_log "AC2 OK"

# ── AC3: no open PRs — exactly one work line, due 0 ───────────────────────────
ac_log "AC3: no open PRs -> one work line with due 0"
T3="${WORK}/tape-ac3"
mkdir -p "$T3"
rc=0
run_poll "$T3" 0 1 || rc=$?
ac_assert_eq "$rc" "0" "AC3: the poll must exit 0 with no open PRs (got $rc)"
n="$(wc -l < "$T3/rollout/evidence/agents-test.jsonl" 2>/dev/null | tr -d '[:space:]')"
ac_assert_eq "$n" "1" "AC3: the no-PRs poll must record exactly one evidence line (got $n)"
line="$(last_evidence_line "$T3")"
ac_assert_jq '.kind == "work" and .due == 0 and .done == 0 and .failed == 0' \
  "$line" "AC3: the no-PRs evidence line must be work due 0 done 0 failed 0, got: $line"
ac_log "AC3 OK"

# ── AC4: TAPE_DIR read-only — the append fails, the poll still exits 0 ─────────
ac_log "AC4: TAPE_DIR read-only -> poll still exits 0"
T4="${WORK}/tape-ac4"
mkdir -p "$T4"
chmod 555 "$T4"
rc=0
run_poll "$T4" 1 || rc=$?
ac_assert_eq "$rc" "0" "AC4: a failed evidence append must never fail the poll (got $rc; stderr: $(cat "$STDERR" 2>/dev/null || true))"
ac_log "AC4 OK"

# ── AC5: issue-1902.sh (no TAPE_DIR) still passes ──────────────────────────────
ac_log "AC5: tests/acceptance/issue-1902.sh still passes"
rc=0
bash "$REPO_ROOT/tests/acceptance/issue-1902.sh" >/dev/null 2>"${WORK}/1902.stderr" || rc=$?
ac_assert_eq "$rc" "0" "AC5: issue-1902.sh must still pass (got $rc: $(cat "${WORK}/1902.stderr" 2>/dev/null || true))"
ac_log "AC5 OK"

ac_pass "issue #2109: each review poll records its reviews due, done and failed"
