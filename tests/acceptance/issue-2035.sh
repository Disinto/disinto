#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2035.sh
#
# Issue #2035: grade.sh is the owner's override (docs/design/proposal-loop.md
# §3), but inside an agent container $USER is `agent`, so an LLM-driven agent
# with a shell could append a grade that calibration reads over the code's
# (#2033). grade.sh must refuse when DISINTO_CONTAINER=1.
#
# Contract under test:
#   (1) DISINTO_CONTAINER=1: exit 77, stderr names "agents never write
#       grades", and the tape gets no new line;
#   (2) DISINTO_CONTAINER=0: exit 0 and appends exactly one grade for p-3;
#   (3) DISINTO_CONTAINER unset: exit 0 and appends exactly one grade for p-3;
#   (4) the guard runs before lib/tape.sh is sourced, so a refusal never
#       creates the tape file at all.
#
# Hermetic: no network, no forge, no agent — a temp TAPE_DIR per scenario with
# a sprint id file sprints/3 holding "p-3", and the real tools/grade.sh
# invoked against it (grade.sh sources lib/tape.sh itself, so TAPE_DIR is the
# single seam).
#
# Acceptance: `bash tests/acceptance/issue-2035.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

GRADE="$REPO_ROOT/tools/grade.sh"
ac_require_cmd bash jq awk
ac_assert_file "$GRADE" "the grading tool under test is missing"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Scenario state, refreshed by every grade_once call below.
declare -g RC=0 OUT="" ERR=""

# grade_once <tape-dir> <flag> <args...> — invoke the real grade.sh with
# TAPE_DIR=<tape-dir>; <flag> is "1", "0", or "-" (leave DISINTO_CONTAINER
# unset). stdout lands in OUT, stderr in ERR, the exit code in RC.
grade_once() {
  tape="$1"
  flag="$2"
  shift 2
  RC=0
  OUT=""
  ERR=""
  if [ "$flag" = "-" ]; then
    env -u DISINTO_CONTAINER TAPE_DIR="$tape" \
      bash "$GRADE" "$@" >"$tape.out" 2>"$tape.err" || RC=$?
  else
    env DISINTO_CONTAINER="$flag" TAPE_DIR="$tape" \
      bash "$GRADE" "$@" >"$tape.out" 2>"$tape.err" || RC=$?
  fi
  OUT="$(cat "$tape.out" 2>/dev/null)"
  ERR="$(cat "$tape.err" 2>/dev/null)"
}

# sprint_tape <name> — a fresh temp tape dir whose sprint id file sprints/3
# holds "p-3" (the file lib/sprint-tape.sh #1618 mints for milestone 3).
sprint_tape() {
  dir="$SCRATCH/$1"
  mkdir -p "$dir/sprints"
  echo p-3 > "$dir/sprints/3"
  echo "$dir"
}

# grades_in <tape-dir> — grade lines on the tape; 0 when the tape file was
# never created (a refusal never reaches _tape_append).
grades_in() {
  awk 'END { print NR }' "$1/tape.jsonl" 2>/dev/null || echo 0
}

# ── AC1: DISINTO_CONTAINER=1 → exit 77, stderr, nothing appended ─────────────
ac_log "AC1: DISINTO_CONTAINER=1 exits 77 and appends nothing"
T1="$(sprint_tape tape-1)"
grade_once "$T1" 1 milestone:3 0.5
ac_assert_eq "$RC" "77" \
  "DISINTO_CONTAINER=1 must exit 77 (rc=$RC): OUT='$OUT' ERR='$ERR'"
[ -z "$OUT" ] || ac_fail "must print nothing to stdout on refusal (got: $OUT)"
grep -qF 'agents never write grades' "$T1.err" \
  || ac_fail "stderr must say 'agents never write grades' (got: $ERR)"
ac_assert_eq "$(grades_in "$T1")" "0" \
  "refusal must append no grade (got $(grades_in "$T1") lines)"

# ── AC2: DISINTO_CONTAINER=0 → exit 0, one grade for p-3 ─────────────────────
ac_log "AC2: DISINTO_CONTAINER=0 exits 0 and appends one grade for p-3"
T2="$(sprint_tape tape-2)"
grade_once "$T2" 0 milestone:3 0.5
ac_assert_eq "$RC" "0" \
  "DISINTO_CONTAINER=0 must exit 0 (rc=$RC): OUT='$OUT' ERR='$ERR'"
ac_assert_eq "$(grades_in "$T2")" "1" \
  "exactly one tape line after the grade (got $(grades_in "$T2"))"
GRADE_LINE="$(tail -n 1 "$T2/tape.jsonl")"
ac_assert_jq '.type == "grade" and .proposal_id == "p-3" and .value == 0.5
    and .when == "at_outcome"' "$GRADE_LINE" \
  "grade must carry proposal_id p-3, value 0.5, when at_outcome (got: $GRADE_LINE)"

# ── AC3: DISINTO_CONTAINER unset → exit 0, one grade for p-3 ─────────────────
ac_log "AC3: DISINTO_CONTAINER unset exits 0 and appends one grade for p-3"
T3="$(sprint_tape tape-3)"
grade_once "$T3" - milestone:3 0.5
ac_assert_eq "$RC" "0" \
  "unset DISINTO_CONTAINER must exit 0 (rc=$RC): OUT='$OUT' ERR='$ERR'"
ac_assert_eq "$(grades_in "$T3")" "1" \
  "exactly one tape line after the grade (got $(grades_in "$T3"))"
GRADE_LINE="$(tail -n 1 "$T3/tape.jsonl")"
ac_assert_jq '.type == "grade" and .proposal_id == "p-3" and .value == 0.5' \
  "$GRADE_LINE" \
  "grade must carry proposal_id p-3 and value 0.5 (got: $GRADE_LINE)"

# ── AC4: the guard precedes lib/tape.sh, so no tape file is ever created ─────
ac_log "AC4: refusal inside a container never creates tape.jsonl"
T4="$SCRATCH/tape-4"
mkdir -p "$T4"
grade_once "$T4" 1 milestone:3 0.5
ac_assert_eq "$RC" "77" "container run must exit 77 (rc=$RC)"
if [ -e "$T4/tape.jsonl" ]; then
  ac_fail "refusal must not create the tape file (got: $(cat "$T4/tape.jsonl"))"
fi

ac_pass
