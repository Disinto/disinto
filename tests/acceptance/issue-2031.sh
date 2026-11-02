#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2031.sh
#
# Issue #2031: the gate has no way to reach the owner. lib/notice.sh adds one
# function (no callers yet) that queues a message for the owner as a file in
# the notices directory under the tape volume; the healer drains the queue
# (#2032). AD-006: nothing under lib/ sends — this lib only writes a file.
#
# Function (sourced):
#   notice_owner TEXT
#     -> queue one notice under ${NOTICES_DIR:-${TAPE_DIR:-/srv/disinto/tape}/notices}
#        (mkdir -p; first 4000 chars of TEXT to a temp file, then mv to
#        <epoch-seconds>-<pid>-<RANDOM>.txt in the same directory)
#        * rc 0: exactly one new .txt file, no .tmp or partial file left
#        * rc 1 with one stderr line: empty TEXT, or the directory or the
#          write fails
#     * never prints TEXT, never sends anything
#
# Hermetic: no network, no forge, no agent — a temp NOTICES_DIR per scenario,
# the lib sourced in a throwaway subshell (same pattern as issue-1618.sh).
#
# Acceptance: `bash tests/acceptance/issue-2031.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_assert_file "$REPO_ROOT/lib/notice.sh" "lib/notice.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_notice <notices_dir> <text>
# Source lib/notice.sh in a throwaway subshell with the scenario's
# NOTICES_DIR and call notice_owner with the given text. stdout -> $OUT,
# stderr -> $ERR, exit status -> $RC.
run_notice() {
  local notices_dir="$1" text="$2"
  RC=0
  OUT=""
  ERR=""
  (
    export NOTICES_DIR="$notices_dir"
    # shellcheck source=../lib/notice.sh
    source "$REPO_ROOT/lib/notice.sh"
    notice_owner "$text"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null)"
}

# txt_count <dir> — number of *.txt files directly in dir.
txt_count() {
  find "$1" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

# entry_count <dir> — number of entries of any kind directly in dir.
entry_count() {
  find "$1" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' '
}

# ── AC1: a queued notice lands as exactly one complete .txt file ─────────────
ac_log "AC1: notice_owner 'hello' queues exactly one complete .txt file"
DIR1="$TMP_DIR/notices-1"
run_notice "$DIR1" "hello"
ac_assert_eq "$RC" "0" "notice_owner 'hello' must return 0 (got $RC): $ERR"
[ -z "$OUT" ] || ac_fail "notice_owner must print nothing on success (got: $OUT)"
ac_assert_eq "$(txt_count "$DIR1")" "1" "exactly one .txt must exist (got $(txt_count "$DIR1"))"
ac_assert_eq "$(entry_count "$DIR1")" "1" "no .tmp or partial file may be left (got $(entry_count "$DIR1") entries)"
FILE1="$(find "$DIR1" -maxdepth 1 -name '*.txt')"
CONTENT="$(cat "$FILE1")"
ac_assert_eq "$CONTENT" "hello" "the queued file must hold 'hello' (got '$CONTENT')"

# ── AC2: two calls queue two files; sort lists them in call order ─────────────
ac_log "AC2: two calls leave two files, sorted in call order"
DIR2="$TMP_DIR/notices-2"
run_notice "$DIR2" "first notice"
ac_assert_eq "$RC" "0" "first call must return 0 (got $RC): $ERR"
FIRST="$(find "$DIR2" -maxdepth 1 -name '*.txt')"
# Cross a second boundary so the epoch prefix orders the two files.
sleep 1
run_notice "$DIR2" "second notice"
ac_assert_eq "$RC" "0" "second call must return 0 (got $RC): $ERR"
ac_assert_eq "$(txt_count "$DIR2")" "2" "two calls must leave two files (got $(txt_count "$DIR2"))"
SORTED="$(find "$DIR2" -maxdepth 1 -name '*.txt' | sort)"
ac_assert_eq "$(printf '%s\n' "$SORTED" | head -n 1)" "$FIRST" \
  "sort of the notices dir must list the first call's file first"
SECOND="$(find "$DIR2" -maxdepth 1 -name '*.txt' | grep -v -F "$FIRST")"
ac_assert_eq "$(printf '%s\n' "$SORTED" | tail -n 1)" "$SECOND" \
  "sort must list the second call's file last"
ac_assert_eq "$(cat "$SECOND")" "second notice" "the second file must hold 'second notice'"

# ── AC3: a 4001-character text is capped to 4000 characters ──────────────────
ac_log "AC3: a 4001-character text leaves a 4000-character file"
DIR3="$TMP_DIR/notices-3"
LONG="$(printf 'a%.0s' {1..4001})"
run_notice "$DIR3" "$LONG"
ac_assert_eq "$RC" "0" "notice_owner with 4001 chars must return 0 (got $RC): $ERR"
ac_assert_eq "$(wc -c < "$(find "$DIR3" -maxdepth 1 -name '*.txt')")" "4000" \
  "the queued file must hold exactly 4000 characters (got $(wc -c < "$(find "$DIR3" -maxdepth 1 -name '*.txt')"))"

# ── AC4: empty text and an unwritable directory fail with one stderr line ─────
ac_log "AC4a: empty text returns 1 and queues nothing"
DIR4="$TMP_DIR/notices-4"
run_notice "$DIR4" ""
ac_assert_eq "$RC" "1" "empty text must return 1 (got $RC)"
ac_assert_eq "$(printf '%s' "$ERR" | grep -c . | tr -d ' ')" "1" \
  "empty text must print exactly one stderr line (got: $ERR)"
[ -z "$OUT" ] || ac_fail "empty text must print nothing to stdout (got: $OUT)"
[ ! -e "$DIR4" ] || ac_fail "empty text must create no directory or file (dir exists: $DIR4)"

ac_log "AC4b: a read-only directory returns 1 with one stderr line"
DIR5="$TMP_DIR/notices-5"
mkdir -p "$DIR5"
chmod 555 "$DIR5"
run_notice "$DIR5" "cannot be written"
ac_assert_eq "$RC" "1" "writing into a read-only dir must return 1 (got $RC)"
ac_assert_eq "$(printf '%s' "$ERR" | grep -c . | tr -d ' ')" "1" \
  "the write failure must print exactly one stderr line (got: $ERR)"
ac_assert_eq "$(txt_count "$DIR5")" "0" "no notice file may be left behind (got $(txt_count "$DIR5"))"
ac_assert_eq "$(entry_count "$DIR5")" "0" "no .tmp or partial file may be left behind (got $(entry_count "$DIR5") entries)"
chmod 755 "$DIR5"

ac_log "AC4c: a directory under a read-only parent returns 1 with one stderr line"
PARENT="$TMP_DIR/parent-6"
mkdir -p "$PARENT"
chmod 555 "$PARENT"
run_notice "$PARENT/notices-6" "cannot be created"
ac_assert_eq "$RC" "1" "mkdir under a read-only parent must return 1 (got $RC)"
ac_assert_eq "$(printf '%s' "$ERR" | grep -c . | tr -d ' ')" "1" \
  "the mkdir failure must print exactly one stderr line (got: $ERR)"
[ ! -e "$PARENT/notices-6" ] || ac_fail "mkdir must not have created $PARENT/notices-6"
chmod 755 "$PARENT"

# ── AC5: the lib never sends — no network code, syntactically valid ──────────
ac_log "AC5: lib/notice.sh names no sender and parses cleanly"
COUNT="$(grep -c -E 'curl|telegram' "$REPO_ROOT/lib/notice.sh" || true)"
ac_assert_eq "$COUNT" "0" "lib/notice.sh must contain no 'curl' or 'telegram' (found $COUNT)"
bash -n "$REPO_ROOT/lib/notice.sh" || ac_fail "bash -n lib/notice.sh failed"

echo PASS
exit 0
