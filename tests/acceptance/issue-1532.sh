#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1532.sh
#
# Issue #1532: close the tape pair when the agent merges or exits.
#
# dev-poll.sh's emit_tape_outcome() only fires when dev-poll itself merges or
# abandons a PR. dev-agent.sh merges via pr_walk_to_merge() and returns, so the
# outcome would never land: Forge closes the issue and the next poll sees no
# open PR, writing nothing. The dev tape pair is left open and the calibration
# p_success stays stuck at the flat prior.
#
# Fix: dev-agent.sh defines close_dev_tape_outcome() and calls it from the EXIT
# trap. The trap preserves the script's original exit code; tape failures log a
# warning and do not change it.
#
# Contract under test (#1532):
#   * id file /tmp/dev-proposal-id-${PROJECT_NAME:-default}-${ISSUE} missing or
#     empty -> write nothing (return 0).
#   * otherwise append exactly one tape_outcome for that id:
#       - bits.merged / bits.ci_green are 1 only when pr_walk_to_merge()
#         returned 0 (flag PR_WALK_RC, set at the walk site); every other exit
#         records 0/0. Never inferred from the process exit code.
#       - numbers.review_rounds is 0 (no forge call).
#       - numbers.duration_s = now - started (clamped >= 0) when the started
#         epoch file is present and an integer; omitted (never 0) otherwise.
#       - children = {}, payloads = [].
#   * At most one outcome per process (a second call appends nothing).
#   * Never deletes the id/started files.
#   * Always returns 0 (a tape failure logs a WARNING).
#
# Hermetic: no network, no forge, no agent. close_dev_tape_outcome is extracted
# from dev/dev-agent.sh and exercised in subshells against a temp TAPE_DIR, the
# same extract-and-stub approach as the other tape tests.
#
# Acceptance: `bash tests/acceptance/issue-1532.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk date
TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev-agent.sh is present"

# --- extract the function under test -----------------------------------------
ac_log "Extracting close_dev_tape_outcome from $TARGET"
FN_CLOSE="$(ac_extract_fn close_dev_tape_outcome "$TARGET")"
[ -n "$FN_CLOSE" ] || ac_fail "close_dev_tape_outcome() is not defined in dev-agent.sh"

# --- wiring: EXIT trap calls close_dev_tape_outcome ---------------------------
grep -q "trap.*close_dev_tape_outcome.*EXIT" "$TARGET" \
  || ac_fail "dev-agent.sh does not install an EXIT trap that calls close_dev_tape_outcome"
# shellcheck disable=SC2016  # '$rc' is a literal in the search pattern
grep -qF 'PR_WALK_RC="$rc"' "$TARGET" \
  || ac_fail "the pr_walk_to_merge success branch must set the merged flag (PR_WALK_RC=rc)"

# --- runtime setup -----------------------------------------------------------
TMP_DIR="$(mktemp -d /tmp/acceptance-1532.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_NAME="acceptance-1532"
ISSUE_TEST=1532
export PROJECT_NAME

ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-${ISSUE_TEST}"
STARTED_FILE="/tmp/dev-proposal-started-${PROJECT_NAME}-${ISSUE_TEST}"

# log() stand-in (inherited by subshells); shadowed again inside the subshell.
log() { printf 'agent: %s\n' "$*"; }

# Run the extracted close_dev_tape_outcome in a fresh subshell.
# $1 TAPE_DIR   $2 PR_WALK_RC (0 merged, 1 not)   $3 number of calls (1|2)
# All calls are in the same process (same subshell), so the "at most one
# outcome per process" guard is exercised when $3 > 1.
run_close() {
  local tape_dir="$1" walk_rc="$2" n="$3"
  (
    export TAPE_DIR="$tape_dir"
    export PROJECT_NAME="$PROJECT_NAME"
    export ISSUE="$ISSUE_TEST"
    export PR_WALK_RC="$walk_rc"
    export LOGFILE="$TMP_DIR/close.log"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    eval "$FN_CLOSE"
    log() { printf 'agent: %s\n' "$*"; }
    i=0
    while [ "$i" -lt "$n" ]; do
      i=$(( i + 1 ))
      close_dev_tape_outcome
    done
  ) 2>&1
}

# Count outcome records in the (possibly absent) JSONL tape at <tape_dir>/
# tape.jsonl.
count_outcomes() {
  local f="$1/tape.jsonl"
  if [ -f "$f" ]; then
    jq -c 'select(.type == "outcome")' "$f" 2>/dev/null | wc -l
  else
    echo 0
  fi
}

# First outcome record's field (e.g. .bits.merged) in the JSONL tape at
# <tape_dir>/tape.jsonl. Empty string when no outcome. Stream-aware (JSONL).
first_outcome() {
  local f="$1/tape.jsonl" p="$2"
  if [ -f "$f" ]; then
    jq -r "select(.type == \"outcome\") | $p" "$f" 2>/dev/null | head -n1
  fi
}

# --- scenario A: id present + flag set -> one outcome, merged/ci_green 1,
#     duration_s equals the started-file span --------------------------------
ac_log "scenario A: id present, PR_WALK_RC=0, started file present"
printf 'dev-proposal-A-1532' > "$ID_FILE"
startedA=$(( $(date -u +%s) - 10 ))
printf '%s\n' "$startedA" > "$STARTED_FILE"
TAPE_A="$TMP_DIR/tapeA"
mkdir -p "$TAPE_A"
NOW_BEFORE="$(date -u +%s)"
rc=0
out="$(run_close "$TAPE_A" 0 1)" || rc=$?
NOW_AFTER="$(date -u +%s)"
rm -f "$ID_FILE" "$STARTED_FILE"

ac_assert_eq "$(count_outcomes "$TAPE_A")" "1" "one outcome recorded (merged flag set): $out"
ac_assert_eq "$(first_outcome "$TAPE_A" .bits.merged)" "1" "merged is 1"
ac_assert_eq "$(first_outcome "$TAPE_A" .bits.ci_green)" "1" "ci_green is 1"
ac_assert_eq "$(first_outcome "$TAPE_A" .numbers.review_rounds)" "0" "review_rounds is 0"
ac_assert_eq "$(first_outcome "$TAPE_A" .children)" '{}' "children is {}"
ac_assert_eq "$(first_outcome "$TAPE_A" .payloads)" '[]' "payloads is []"
durA="$(first_outcome "$TAPE_A" .numbers.duration_s)"
[ -n "$durA" ] || ac_fail "duration_s present when started file present (got '$durA')"
[[ "$durA" =~ ^[0-9]+$ ]] || ac_fail "duration_s is an integer (got '$durA')"
loA=$(( NOW_BEFORE - startedA ))
hiA=$(( NOW_AFTER - startedA ))
[ "$durA" -ge "$loA" ] || ac_fail "duration_s lower bound (expected >= $loA, got $durA)"
[ "$durA" -le "$hiA" ] || ac_fail "duration_s upper bound (expected <= $hiA, got $durA)"
ac_log "  -> duration_s=$durA (started $startedA, expected ~10)"

# --- scenario B: id present + flag unset -> one outcome, merged/ci_green 0 ---
ac_log "scenario B: id present, PR_WALK_RC=1, started file present"
printf 'dev-proposal-B-1532' > "$ID_FILE"
printf '%s\n' "$startedA" > "$STARTED_FILE"
TAPE_B="$TMP_DIR/tapeB"
mkdir -p "$TAPE_B"
rc=0
out="$(run_close "$TAPE_B" 1 1)" || rc=$?
rm -f "$ID_FILE" "$STARTED_FILE"

ac_assert_eq "$(count_outcomes "$TAPE_B")" "1" "one outcome recorded (flag unset): $out"
ac_assert_eq "$(first_outcome "$TAPE_B" .bits.merged)" "0" "merged is 0 (flag unset)"
ac_assert_eq "$(first_outcome "$TAPE_B" .bits.ci_green)" "0" "ci_green is 0 (flag unset)"
ac_assert_eq "$(first_outcome "$TAPE_B" .numbers.review_rounds)" "0" "review_rounds is 0"
ac_assert_eq "$(first_outcome "$TAPE_B" .children)" '{}' "children is {}"
ac_assert_eq "$(first_outcome "$TAPE_B" .payloads)" '[]' "payloads is []"

# --- scenario C: id absent -> no outcome line -------------------------------
ac_log "scenario C: no id file -> no outcome"
rm -f "$ID_FILE" "$STARTED_FILE"
TAPE_C="$TMP_DIR/tapeC"
mkdir -p "$TAPE_C"
rc=0
out="$(run_close "$TAPE_C" 0 1)" || rc=$?
ac_assert_eq "$(count_outcomes "$TAPE_C")" "0" "no outcome line when id file absent: $out"

# --- scenario D: same process, two calls -> exactly one outcome --------------
ac_log "scenario D: two calls in the same process -> one outcome"
printf 'dev-proposal-D-1532' > "$ID_FILE"
printf '%s\n' "$startedA" > "$STARTED_FILE"
TAPE_D="$TMP_DIR/tapeD"
mkdir -p "$TAPE_D"
rc=0
out="$(run_close "$TAPE_D" 0 2)" || rc=$?
rm -f "$ID_FILE" "$STARTED_FILE"

ac_assert_eq "$(count_outcomes "$TAPE_D")" "1" "second call in the same process appended nothing: $out"

# --- scenario E: unwritable TAPE_DIR -> returns 0 ---------------------------
ac_log "scenario E: unwritable TAPE_DIR -> returns 0"
touch "$TMP_DIR/blocker"
TAPE_E="$TMP_DIR/blocker/tape"
printf 'dev-proposal-E-1532' > "$ID_FILE"
rc=0
out="$(run_close "$TAPE_E" 0 1)" || rc=$?
rm -f "$ID_FILE"
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must return 0 (got $rc): $out"

# --- scenario F: started file absent -> duration_s omitted (never 0) --------
ac_log "scenario F: no started file -> duration_s omitted (never 0)"
printf 'dev-proposal-F-1532' > "$ID_FILE"
rm -f "$STARTED_FILE"
TAPE_F="$TMP_DIR/tapeF"
mkdir -p "$TAPE_F"
rc=0
out="$(run_close "$TAPE_F" 0 1)" || rc=$?
rm -f "$ID_FILE" "$STARTED_FILE"

ac_assert_eq "$(count_outcomes "$TAPE_F")" "1" "one outcome recorded (no started file): $out"
ac_assert_eq "$(first_outcome "$TAPE_F" .bits.merged)" "1" "merged is 1"
ac_assert_eq "$(first_outcome "$TAPE_F" .numbers.duration_s)" "null" \
  "duration_s omitted (never 0) when started file absent: $out"

# --- id/started files must not be deleted by the run ------------------------
printf 'dev-proposal-G-1532' > "$ID_FILE"
printf '%s\n' "$startedA" > "$STARTED_FILE"
TAPE_G="$TMP_DIR/tapeG"
mkdir -p "$TAPE_G"
run_close "$TAPE_G" 0 1 >/dev/null 2>&1
ac_assert_file "$ID_FILE" "id file is not deleted by close_dev_tape_outcome"
ac_assert_file "$STARTED_FILE" "started file is not deleted by close_dev_tape_outcome"
rm -f "$ID_FILE" "$STARTED_FILE"

ac_pass "issue #1532: dev-agent.sh closes the tape pair via the EXIT trap"
