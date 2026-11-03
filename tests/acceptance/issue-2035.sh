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
#       creates the tape directory's tape.jsonl at all.
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

TOOL="$REPO_ROOT/tools/grade.sh"
ac_require_cmd bash jq
ac_assert_file "$TOOL" "tools/grade.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# RC/OUT/ERR are the run state consumed by every scenario below.
RC=0
OUT=""
ERR=""

# run_grade <tape-dir> <container-env> <args...>
# Invoke the real grade.sh with TAPE_DIR=<tape-dir> and the DISINTO_CONTAINER
# env set to <container-env> ("1", "0", or "-" for unset), capturing stdout to
# <tape-dir>.out, stderr to <tape-dir>.err, and the exit code into RC.
run_grade() {
  local tape_dir="$1"
  local container_env="$2"
  shift 2
  RC=0
  OUT=""
  ERR=""
  if [ "$container_env" = "-" ]; then
    env -u DISINTO_CONTAINER TAPE_DIR="$tape_dir" \
      bash "$TOOL" "$@" >"$tape_dir.out" 2>"$tape_dir.err" || RC=$?
  else
    env DISINTO_CONTAINER="$container_env" TAPE_DIR="$tape_dir" \
      bash "$TOOL" "$@" >"$tape_dir.out" 2>"$tape_dir.err" || RC=$?
  fi
  OUT="$(cat "$tape_dir.out" 2>/dev/null)"
  ERR="$(cat "$tape_dir.err" 2>/dev/null)"
}

# fresh_tape <name> — temp TAPE_DIR with sprints/3 = "p-3" (the sprint id file
# minted by lib/sprint-tape.sh, #1618).
fresh_tape() {
  local tape_dir="$TMP_DIR/$1"
  mkdir -p "$tape_dir/sprints"
  printf '%s\n' "p-3" > "$tape_dir/sprints/3"
  echo "$tape_dir"
}

# line_count <tape-dir> — number of tape.jsonl lines, or 0 when the tape is
# absent (a refusal never reaches _tape_append, so nothing is created).
line_count() {
  if [ -f "$1/tape.jsonl" ]; then
    wc -l < "$1/tape.jsonl" | tr -d '[:space:]'
  else
    echo 0
  fi
}

# ── AC1: DISINTO_CONTAINER=1 → exit 77, stderr, nothing appended ─────────────
ac_log "AC1: DISINTO_CONTAINER=1 exits 77 and appends nothing"
TAPE_1="$(fresh_tape tape-1)"
run_grade "$TAPE_1" 1 milestone:3 0.5
ac_assert_eq "$RC" "77" \
  "DISINTO_CONTAINER=1 must exit 77 (rc=$RC): OUT='$OUT' ERR='$ERR'"
[ -z "$OUT" ] || ac_fail "must print nothing to stdout on refusal (got: $OUT)"
grep -qF 'agents never write grades' "$TAPE_1.err" \
  || ac_fail "stderr must say 'agents never write grades' (got: $ERR)"
ac_assert_eq "$(line_count "$TAPE_1")" "0" \
  "refusal must append no grade (got $(line_count "$TAPE_1") lines)"

# ── AC2: DISINTO_CONTAINER=0 → exit 0, one grade for p-3 ─────────────────────
ac_log "AC2: DISINTO_CONTAINER=0 exits 0 and appends one grade for p-3"
TAPE_2="$(fresh_tape tape-2)"
run_grade "$TAPE_2" 0 milestone:3 0.5
ac_assert_eq "$RC" "0" \
  "DISINTO_CONTAINER=0 must exit 0 (rc=$RC): OUT='$OUT' ERR='$ERR'"
ac_assert_eq "$(line_count "$TAPE_2")" "1" \
  "exactly one tape line after the grade (got $(line_count "$TAPE_2"))"
LAST_LINE="$(tail -n 1 "$TAPE_2/tape.jsonl")"
ac_assert_jq '.type == "grade" and .proposal_id == "p-3" and .value == 0.5
    and .when == "at_outcome"' "$LAST_LINE" \
  "grade must carry proposal_id p-3, value 0.5, when at_outcome (got: $LAST_LINE)"

# ── AC3: DISINTO_CONTAINER unset → exit 0, one grade for p-3 ─────────────────
ac_log "AC3: DISINTO_CONTAINER unset exits 0 and appends one grade for p-3"
TAPE_3="$(fresh_tape tape-3)"
run_grade "$TAPE_3" - milestone:3 0.5
ac_assert_eq "$RC" "0" \
  "unset DISINTO_CONTAINER must exit 0 (rc=$RC): OUT='$OUT' ERR='$ERR'"
ac_assert_eq "$(line_count "$TAPE_3")" "1" \
  "exactly one tape line after the grade (got $(line_count "$TAPE_3"))"
LAST_LINE="$(tail -n 1 "$TAPE_3/tape.jsonl")"
ac_assert_jq '.type == "grade" and .proposal_id == "p-3" and .value == 0.5' \
  "$LAST_LINE" \
  "grade must carry proposal_id p-3 and value 0.5 (got: $LAST_LINE)"

# ── AC4: the guard precedes lib/tape.sh, so no tape file is ever created ─────
ac_log "AC4: refusal inside a container never creates tape.jsonl"
TAPE_4="$TMP_DIR/tape-4"
mkdir -p "$TAPE_4"
run_grade "$TAPE_4" 1 milestone:3 0.5
ac_assert_eq "$RC" "77" "container run must exit 77 (rc=$RC)"
if [ -f "$TAPE_4/tape.jsonl" ]; then
  ac_fail "refusal must not create the tape file at all (got: $(cat "$TAPE_4/tape.jsonl"))"
fi

ac_pass
