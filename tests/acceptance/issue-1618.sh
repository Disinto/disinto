#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1618.sh
#
# Issue #1618: sprints never reach the tape, so no dev proposal has a `parent`
# and nothing is graded at sprint level. A sprint is a Forgejo milestone; the
# tape needs one `sprint`-loop proposal per milestone, created once and found
# without scanning the tape. The sprint's class is its nature (deploy,
# experiment, internal), read by the caller from the milestone's sprint block.
#
# lib/sprint-tape.sh provides one function (no callers yet):
#   sprint_proposal_id MILESTONE_ID CLASS
#     -> id of that milestone's sprint proposal
#       * id file ${TAPE_DIR}/sprints/<MILESTONE_ID> holds an id -> print it,
#         return 0, append nothing; an empty file counts as absent
#       * otherwise exclusive flock on ${TAPE_DIR}/sprints/.lock, check again,
#         mint a fresh id (uuidgen -> kernel uuid, same as
#         emit_tape_proposal in dev/dev-poll.sh), append
#           tape_proposal "$id" sprint "$class" "" "" '{}' '' "approved"
#           "milestone:<MILESTONE_ID>"   (no forecast), write the id file only
#         after a successful append, print the id, return 0
#       * class: the given CLASS when it matches ^[a-z][a-z0-9-]*$, otherwise
#         "unclassed"
#       * non-integer MILESTONE_ID or append failure: print nothing, return 1,
#         write no id file
#
# Hermetic: no network, no forge, no agent — a temp TAPE_DIR per scenario, the
# lib sourced in a throwaway subshell (same pattern as the other tape tests,
# e.g. issue-1616.sh).
#
# Acceptance: `bash tests/acceptance/issue-1618.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock
ac_assert_file "$REPO_ROOT/lib/sprint-tape.sh" "lib/sprint-tape.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_sprint <tape_dir> <out_file> <err_file> <args...>
# Source lib/sprint-tape.sh (which sources lib/tape.sh) in a throwaway
# subshell with the scenario's TAPE_DIR and call sprint_proposal_id with the
# given args. stdout -> <out_file>, stderr -> <err_file>, exit status -> $RC.
run_sprint() {
  local tape_dir="$1" out_file="$2" err_file="$3"
  shift 3
  RC=0
  OUT=""
  ERR=""
  (
    export TAPE_DIR="$tape_dir"
    # shellcheck source=../lib/sprint-tape.sh
    source "$REPO_ROOT/lib/sprint-tape.sh"
    sprint_proposal_id "$@"
  ) >"$out_file" 2>"$err_file" || RC=$?
  OUT="$(cat "$out_file" 2>/dev/null)"
  ERR="$(cat "$err_file" 2>/dev/null)"
}

# ── AC1: sprint_proposal_id 7 deploy — one sprint proposal, no forecast ─────
ac_log "AC1: first 7 deploy call appends one sprint proposal"
TAPE_1="$TMP_DIR/tape-1"
mkdir -p "$TAPE_1"
run_sprint "$TAPE_1" "$TMP_DIR/out-1" "$TMP_DIR/err-1" 7 deploy
ac_assert_eq "$RC" "0" \
  "first 7 deploy call must return 0 (got $RC): $OUT | $ERR"
[ -n "$OUT" ] || ac_fail "first call must print the proposal id (got empty)"
ac_assert_eq "$(wc -l < "$TAPE_1/tape.jsonl")" "1" \
  "exactly one tape line after the first call (got $(wc -l < "$TAPE_1/tape.jsonl"))"
LINE="$(head -n1 "$TAPE_1/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "sprint" and .class == "deploy"
    and .decision == "approved" and .ref == "milestone:7" and (.parent | not)
    and (.caused_by | not) and (.forecast | not)' "$LINE" \
  "record must be an approved sprint proposal with no parent/caused_by/forecast"
[ -f "$TAPE_1/sprints/7" ] || ac_fail "id file missing after the first call"
ac_assert_eq "$(cat "$TAPE_1/sprints/7")" "$OUT" \
  "id file must hold the printed id (file: $(cat "$TAPE_1/sprints/7"), printed: $OUT)"
ID_7="$OUT"

# ── AC2: a second 7 deploy call reuses the id, appends nothing ───────────────
ac_log "AC2: a second 7 deploy call reuses the id"
run_sprint "$TAPE_1" "$TMP_DIR/out-2" "$TMP_DIR/err-2" 7 deploy
ac_assert_eq "$RC" "0" \
  "second 7 deploy call must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$OUT" "$ID_7" \
  "second call must print the same id (got $OUT, want $ID_7)"
ac_assert_eq "$(wc -l < "$TAPE_1/tape.jsonl")" "1" \
  "second call must append nothing (got $(wc -l < "$TAPE_1/tape.jsonl") lines)"

# ── AC3: sprint_proposal_id 8 "" — empty class -> unclassed ─────────────────
ac_log "AC3: 8 with empty class writes class=unclassed"
TAPE_2="$TMP_DIR/tape-2"
mkdir -p "$TAPE_2"
run_sprint "$TAPE_2" "$TMP_DIR/out-3" "$TMP_DIR/err-3" 8 ""
ac_assert_eq "$RC" "0" \
  "8 with empty class must return 0 (got $RC): $OUT | $ERR"
[ -n "$OUT" ] || ac_fail "8 with empty class must print the proposal id (got empty)"
ac_assert_eq "$(wc -l < "$TAPE_2/tape.jsonl")" "1" \
  "exactly one tape line (got $(wc -l < "$TAPE_2/tape.jsonl"))"
LINE="$(head -n1 "$TAPE_2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "sprint" and .class == "unclassed"
    and .decision == "approved" and .ref == "milestone:8" and (.forecast | not)' "$LINE" \
  "empty class must write class=unclassed"

# ── AC4: sprint_proposal_id abc deploy — rc 1, nothing printed/appended ─────
ac_log "AC4: non-integer milestone id returns 1, appends nothing"
TAPE_3="$TMP_DIR/tape-3"
mkdir -p "$TAPE_3"
run_sprint "$TAPE_3" "$TMP_DIR/out-4" "$TMP_DIR/err-4" abc deploy
ac_assert_eq "$RC" "1" \
  "non-integer milestone id must return 1 (got $RC): $OUT | $ERR"
[ -z "$OUT" ] || ac_fail "non-integer milestone id must print nothing (got: $OUT)"
[ ! -f "$TAPE_3/tape.jsonl" ] || ac_fail "non-integer milestone id must not append"
[ ! -f "$TAPE_3/sprints/abc" ] || ac_fail "non-integer milestone id must write no id file"

ac_pass "issue #1618: sprint proposal from a Forgejo milestone"
