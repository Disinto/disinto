#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2121.sh
#
# Issue #2121: lib/wall-notice.sh — one owner notice for a PR that changes a
# protected file (docs/design/notes/self-update.md, "The wall"). A PR waiting
# on the wall (lib/wall.sh, #2120) queues one owner notice (lib/notice.sh,
# #2031) per PR, marked in ${TAPE_DIR}/wall/pr-<PR_NUM>.told.
#
#   wall_notice_once PR_NUM [PR_JSON]   (sourced; FORGE_TOKEN + FORGE_API)
#     * marker present -> 0, no notice
#     * GET ${FORGE_API}/pulls/<PR_NUM>/files?limit=50; failed GET -> 0,
#       nothing written
#     * wall_hits disinto on the .filenames; no hits -> 0, no notice, no marker
#     * hits: one notice naming up to 5 files and PR_JSON's html_url; the
#       marker lands only when the notice is queued
#     * always returns 0
#
# Hermetic: a stub curl answers the files GET; a temp TAPE_DIR and NOTICES_DIR
# per scenario. No forge, no network (same pattern as issue-2120.sh).
#
# Acceptance: `bash tests/acceptance/issue-2121.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq

WN="$REPO_ROOT/lib/wall-notice.sh"
ac_assert_file "$WN" "lib/wall-notice.sh is missing"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue-2121.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Stub curl: the last argument is the URL. PR 5 changes tools/rollout.sh and
# README.md; PR 7 changes README.md only. AC_WN_FAIL=1 fails every call with
# exit 22 (the unreachable-API seam); unknown URLs also exit 22. Every URL is
# recorded in AC_WN_LOG so the caller can assert the exact GET.
STUB_BIN="$TMP_DIR/stub"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'AC_WN_CURL_STUB'
#!/usr/bin/env bash
if [ "${AC_WN_FAIL:-}" = "1" ]; then
  exit 22
fi
url="${*: -1}"
if [ -n "${AC_WN_LOG:-}" ]; then
  printf '%s\n' "$url" >> "$AC_WN_LOG"
fi
case "$url" in
  *'/pulls/5/files'*)
    printf '%s\n' '[{"filename":"tools/rollout.sh","sha":"a1"},{"filename":"README.md","sha":"b2"}]'
    ;;
  *'/pulls/7/files'*)
    printf '%s\n' '[{"filename":"README.md","sha":"b2"}]'
    ;;
  *)
    exit 22
    ;;
esac
AC_WN_CURL_STUB
chmod +x "$STUB_BIN/curl"

# run_wall_notice <tape_dir> <notices_dir> <pr> [pr_json] [stub_fail]
# Source lib/wall-notice.sh in a throwaway subshell with the scenario's
# TAPE_DIR/NOTICES_DIR and the stub curl on PATH, then call wall_notice_once.
# stdout -> $OUT, stderr -> $ERR, exit status -> $RC.
run_wall_notice() {
  local tape="$1" notices="$2" pr="$3" pr_json="${4:-}" fail="${5:-0}"
  RC=0 OUT="" ERR=""
  (
    export PATH="$STUB_BIN:$PATH"
    export FORGE_API="https://forge.example/api/v1"
    export FORGE_TOKEN="stub-token"
    export TAPE_DIR="$tape"
    export NOTICES_DIR="$notices"
    export AC_WN_FAIL="$fail"
    export AC_WN_LOG="$TMP_DIR/gets.txt"
    # shellcheck source=../lib/wall-notice.sh
    source "$WN"
    if [ -n "$pr_json" ]; then
      wall_notice_once "$pr" "$pr_json"
    else
      wall_notice_once "$pr"
    fi
  ) >"$TMP_DIR/wn.stdout" 2>"$TMP_DIR/wn.stderr" || RC=$?
  OUT="$(cat "$TMP_DIR/wn.stdout" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/wn.stderr" 2>/dev/null || true)"
}

# notice_count <dir> — number of *.txt files directly in dir.
notice_count() {
  find "$1" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

# ── AC1: walled files -> exactly one notice, and the marker ──────────────────
ac_log "AC1: PR 5 (tools/rollout.sh + README.md) queues one notice and writes the marker"
TAPE1="$TMP_DIR/tape-1"
NOTICES1="$TMP_DIR/notices-1"
: > "$TMP_DIR/gets.txt"
run_wall_notice "$TAPE1" "$NOTICES1" 5 '{"html_url":"https://f/p/5"}'
ac_assert_eq "$RC" "0" "wall_notice_once must always return 0 (got $RC): $ERR"
[ -z "$OUT" ] || ac_fail "wall_notice_once must print nothing to stdout (got: $OUT)"
ac_assert_eq "$(notice_count "$NOTICES1")" "1" "exactly one notice file must be queued (got $(notice_count "$NOTICES1"))"
NOTICE1="$(find "$NOTICES1" -maxdepth 1 -name '*.txt')"
TEXT1="$(cat "$NOTICE1")"
case "$TEXT1" in
  *'#5'*) ;;
  *) ac_fail "the notice must name PR #5, got: $TEXT1" ;;
esac
case "$TEXT1" in
  *'tools/rollout.sh'*) ;;
  *) ac_fail "the notice must name the walled file tools/rollout.sh, got: $TEXT1" ;;
esac
case "$TEXT1" in
  *'https://f/p/5'*) ;;
  *) ac_fail "the notice must carry the PR html_url, got: $TEXT1" ;;
esac
case "$TEXT1" in
  *'README.md'*) ac_fail "the notice must not name a file that is not walled, got: $TEXT1" ;;
esac
ac_assert_file "$TAPE1/wall/pr-5.told" "the marker ${TAPE1}/wall/pr-5.told must exist"
ac_assert_eq "$(grep -c '/pulls/5/files?limit=50' "$TMP_DIR/gets.txt" | tr -d ' ')" "1" \
  "the files GET must hit /pulls/5/files?limit=50"

# ── AC2: the marker blocks a second notice ───────────────────────────────────
ac_log "AC2: a second call for PR 5 queues no new notice"
run_wall_notice "$TAPE1" "$NOTICES1" 5 '{"html_url":"https://f/p/5"}'
ac_assert_eq "$RC" "0" "the second call must return 0 (got $RC): $ERR"
ac_assert_eq "$(notice_count "$NOTICES1")" "1" "the marker must prevent a second notice (got $(notice_count "$NOTICES1"))"

# ── AC3: no wall hit -> no notice, no marker ──────────────────────────────────
ac_log "AC3: PR 7 (README.md only) queues no notice and writes no marker"
TAPE3="$TMP_DIR/tape-3"
NOTICES3="$TMP_DIR/notices-3"
run_wall_notice "$TAPE3" "$NOTICES3" 7
ac_assert_eq "$RC" "0" "wall_notice_once must return 0 with no hits (got $RC): $ERR"
ac_assert_eq "$(notice_count "$NOTICES3")" "0" "no notice may be queued for an unwalled PR (got $(notice_count "$NOTICES3"))"
if [ -e "$TAPE3/wall/pr-7.told" ]; then
  ac_fail "no marker may be written when nothing hit the wall"
fi

# ── AC4: a failing GET -> no notice, no marker, still 0 ───────────────────────
ac_log "AC4: a failing files GET returns 0 with nothing queued"
TAPE4="$TMP_DIR/tape-4"
NOTICES4="$TMP_DIR/notices-4"
run_wall_notice "$TAPE4" "$NOTICES4" 5 '{"html_url":"https://f/p/5"}' 1
ac_assert_eq "$RC" "0" "a failed GET must still return 0 (got $RC): $ERR"
ac_assert_eq "$(notice_count "$NOTICES4")" "0" "a failed GET must queue no notice (got $(notice_count "$NOTICES4"))"
if [ -e "$TAPE4/wall/pr-5.told" ]; then
  ac_fail "a failed GET must write no marker"
fi

# ── AC5: the module sources lib/wall.sh and lib/notice.sh and parses cleanly ──
ac_log "AC5: lib/wall-notice.sh sources the wall and the notice libs, and parses cleanly"
grep -F 'wall.sh' "$WN" >/dev/null || ac_fail "lib/wall-notice.sh must source lib/wall.sh"
grep -F 'notice.sh' "$WN" >/dev/null || ac_fail "lib/wall-notice.sh must source lib/notice.sh"
bash -n "$WN" || ac_fail "bash -n lib/wall-notice.sh failed"

echo PASS
exit 0
