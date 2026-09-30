#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1621.sh
#
# Issue #1621: grade.sh grades on the -1..1 scale and takes a milestone number.
#
# Sprints are hand-graded, but a sprint's tape proposal id lives only in
# ${TAPE_DIR}/sprints/<N> (minted by lib/sprint-tape.sh, #1618). grade.sh
# must (a) resolve `milestone:<N>` to that id and (b) bound the value to
# -1..1 (negative = the sprint moved away from the vision). Any other first
# argument behaves as before.
#
# Contract under test:
#   (1) with ${TAPE_DIR}/sprints/7 = "abc", `milestone:7 0.8` appends a grade
#       record with proposal_id "abc" and exits 0;
#   (2) `milestone:8 0.8` with no id file exits 64, appends nothing, and
#       stderr carries "grade: no sprint proposal for milestone 8";
#   (3) an EMPTY id file is also treated as absent (same convention as
#       sprint-tape.sh's re-pick guard) and exits 64;
#   (4) out-of-range: `abc 1.5` and `abc -2` exit 64, append nothing, and
#       stderr carries "grade: value must be between -1 and 1";
#   (5) in-range: `abc -0.5`, `abc 0.8`, boundary `abc -1` and `abc 1` each
#       append a grade line (boundaries -1 and 1 are inclusive);
#   (6) regression: a bare proposal id still behaves as before — a valid
#       value + explicit `when` appends, non-float/unknown `when` exit 64.
#
# Hermetic: no network, no forge, no agent — a temp TAPE_DIR per scenario and
# the real tools/grade.sh invoked against it (grade.sh sources lib/tape.sh
# itself, so TAPE_DIR is the single seam).
#
# Acceptance: `bash tests/acceptance/issue-1621.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TOOL="$REPO_ROOT/tools/grade.sh"
ac_require_cmd bash jq flock
ac_assert_file "$TOOL" "tools/grade.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# RC/OUT/ERR are the run state consumed by every scenario below.
RC=0
OUT=""
ERR=""

# run_grade <tape-dir> <out-file> <err-file> <args...>
# Invoke the real grade.sh with TAPE_DIR=<tape-dir>, capturing stdout to
# <out-file>, stderr to <err-file>, and the exit code into RC. $OUT/$ERR
# hold the captured bodies.
run_grade() {
  local tape_dir="$1"
  local out_file="$2"
  local err_file="$3"
  shift 3
  RC=0
  OUT=""
  ERR=""
  TAPE_DIR="$tape_dir" bash "$TOOL" "$@" >"$out_file" 2>"$err_file" || RC=$?
  OUT="$(cat "$out_file" 2>/dev/null)"
  ERR="$(cat "$err_file" 2>/dev/null)"
}

# line_count <tape-dir> — number of tape.jsonl lines, or 0 when the tape is
# absent (the error path never reaches _tape_append, so nothing is created).
line_count() {
  if [ -f "$1/tape.jsonl" ]; then
    wc -l < "$1/tape.jsonl" | tr -d '[:space:]'
  else
    echo 0
  fi
}

# last_value <tape-dir> — the value of the final grade line (jq -r numeric).
last_value() {
  tail -n 1 "$1/tape.jsonl" | jq -r '.value'
}

# ── AC1: milestone:7 0.8 resolves sprints/7 = "abc" and grades it ────────────
ac_log "AC1: milestone:7 with an id file grades proposal abc"
TAPE_1="$TMP_DIR/tape-1"
mkdir -p "$TAPE_1/sprints"
printf '%s\n' "abc" > "$TAPE_1/sprints/7"
run_grade "$TAPE_1" "$TMP_DIR/o1" "$TMP_DIR/e1" milestone:7 0.8
ac_assert_eq "$RC" "0" \
  "milestone:7 with id file must return 0 (rc=$RC): OUT='$OUT' ERR='$ERR'"
[ -n "$OUT" ] || ac_fail "must print the appended grade line (stdout empty)"
ac_assert_eq "$(line_count "$TAPE_1")" "1" \
  "exactly one tape line after the grade (got $(line_count "$TAPE_1"))"
LAST_LINE="$(tail -n 1 "$TAPE_1/tape.jsonl")"
ac_assert_jq '.type == "grade" and .proposal_id == "abc" and .value == 0.8
    and .when == "at_outcome"' "$LAST_LINE" \
  "grade must carry proposal_id abc, value 0.8, when at_outcome (got: $LAST_LINE)"

# ── AC2: milestone:8 0.8 with no id file → 64, nothing appended ──────────────
ac_log "AC2: milestone:8 with no id file exits 64, appends nothing"
TAPE_2="$TMP_DIR/tape-2"
mkdir -p "$TAPE_2"
run_grade "$TAPE_2" "$TMP_DIR/o2" "$TMP_DIR/e2" milestone:8 0.8
ac_assert_eq "$RC" "64" \
  "milestone:8 with no id file must exit 64 (rc=$RC): ERR='$ERR'"
[ -z "$OUT" ] || ac_fail "must print nothing to stdout on the no-id path (got: $OUT)"
grep -qF 'grade: no sprint proposal for milestone 8' "$TMP_DIR/e2" \
  || ac_fail "stderr must say 'no sprint proposal for milestone 8' (got: $ERR)"
ac_assert_eq "$(line_count "$TAPE_2")" "0" "must append nothing (got $(line_count "$TAPE_2") lines)"

# ── AC3: an empty id file counts as absent → 64 ───────────────────────────────
ac_log "AC3: an empty id file is treated as absent and exits 64"
TAPE_3="$TMP_DIR/tape-3"
mkdir -p "$TAPE_3/sprints"
: > "$TAPE_3/sprints/7"
run_grade "$TAPE_3" "$TMP_DIR/o3" "$TMP_DIR/e3" milestone:7 0.8
ac_assert_eq "$RC" "64" \
  "milestone:7 with an empty id file must exit 64 (rc=$RC): ERR='$ERR'"
grep -qF 'grade: no sprint proposal for milestone 7' "$TMP_DIR/e3" \
  || ac_fail "empty id file must say 'no sprint proposal for milestone 7' (got: $ERR)"
ac_assert_eq "$(line_count "$TAPE_3")" "0" "empty id file must append nothing"

# ── AC4: out-of-range values → 64, nothing appended ──────────────────────────
ac_log "AC4: values outside -1..1 exit 64 and append nothing"
TAPE_4="$TMP_DIR/tape-4"
mkdir -p "$TAPE_4"
run_grade "$TAPE_4" "$TMP_DIR/o4a" "$TMP_DIR/e4a" abc 1.5
ac_assert_eq "$RC" "64" "abc 1.5 (above 1) must exit 64 (rc=$RC): ERR='$ERR'"
grep -qF 'grade: value must be between -1 and 1' "$TMP_DIR/e4a" \
  || ac_fail "above-1 value must say 'value must be between -1 and 1' (got: $ERR)"
ac_assert_eq "$(line_count "$TAPE_4")" "0" "above-1 must append nothing"
run_grade "$TAPE_4" "$TMP_DIR/o4b" "$TMP_DIR/e4b" abc -2
ac_assert_eq "$RC" "64" "abc -2 (below -1) must exit 64 (rc=$RC): ERR='$ERR'"
grep -qF 'grade: value must be between -1 and 1' "$TMP_DIR/e4b" \
  || ac_fail "below-1 value must say 'value must be between -1 and 1' (got: $ERR)"
ac_assert_eq "$(line_count "$TAPE_4")" "0" "below-1 must append nothing"

# ── AC5: in-range values (incl. boundaries -1 and 1) each append a grade ─────
ac_log "AC5: in-range values -0.5, 0.8, -1 and 1 each append a grade line"
TAPE_5="$TMP_DIR/tape-5"
mkdir -p "$TAPE_5"
for v in -0.5 0.8 -1 1; do
  run_grade "$TAPE_5" "$TMP_DIR/o5" "$TMP_DIR/e5" abc "$v"
  ac_assert_eq "$RC" "0" "abc $v must return 0 (rc=$RC): ERR='$ERR'"
  ac_assert_eq "$(last_value "$TAPE_5")" "$v" \
    "abc $v must append a grade with value $v (last value=$(last_value "$TAPE_5"))"
done
ac_assert_eq "$(line_count "$TAPE_5")" "4" \
  "in-range group must append 4 grade lines (got $(line_count "$TAPE_5"))"

# ── AC6: regression — bare proposal ids behave as before ─────────────────────
ac_log "AC6: a bare proposal id behaves as before (unchanged contract)"
TAPE_6="$TMP_DIR/tape-6"
mkdir -p "$TAPE_6"
run_grade "$TAPE_6" "$TMP_DIR/o6" "$TMP_DIR/e6" p-1 0.85 at_approval
ac_assert_eq "$RC" "0" "bare id p-1 0.85 at_approval must return 0 (rc=$RC): ERR='$ERR'"
LAST_LINE="$(tail -n 1 "$TAPE_6/tape.jsonl")"
ac_assert_jq '.type == "grade" and .proposal_id == "p-1" and .value == 0.85
    and .when == "at_approval"' "$LAST_LINE" \
  "bare id must grade p-1 with value 0.85, when at_approval (got: $LAST_LINE)"
# non-float and unknown `when` still exit 64 (unchanged).
run_grade "$TAPE_6" "$TMP_DIR/o6b" "$TMP_DIR/e6b" p-1 high
ac_assert_eq "$RC" "64" "non-float value must exit 64 (rc=$RC)"
run_grade "$TAPE_6" "$TMP_DIR/o6c" "$TMP_DIR/e6c" p-1 0.5 mid_flight
ac_assert_eq "$RC" "64" "unknown when must exit 64 (rc=$RC)"
ac_assert_eq "$(line_count "$TAPE_6")" "1" \
  "regressions must append only the one valid grade (got $(line_count "$TAPE_6"))"

ac_pass "issue #1621: grade.sh resolves milestone:<N> and grades from -1 to 1"
