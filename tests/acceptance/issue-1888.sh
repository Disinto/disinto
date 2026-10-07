#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1888.sh
#
# Issue #1888: sprint_proposal_id takes the context of the sprint proposal it
# mints. A pitch is an ops-repo PR; when it is decided, that PR number is
# recorded on the milestone's one sprint proposal as context.pitch.
#
# lib/sprint-tape.sh:
#   sprint_proposal_id MILESTONE_ID CLASS [CONTEXT_JSON]
#     CONTEXT_JSON is the proposal's context, a JSON object; default {}.
#     Ignored when the id file already holds an id. A context that is not a
#     JSON object is an append failure (tape_proposal rc 1): print nothing,
#     return 1, write no id file.
#
# Hermetic: no network, no forge, no agent — a temp TAPE_DIR per scenario.
#
# Acceptance: `bash tests/acceptance/issue-1888.sh` exits 0 and calls ac_pass.
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
# Source lib/sprint-tape.sh in a throwaway subshell with the scenario's
# TAPE_DIR and call sprint_proposal_id. stdout -> <out_file>, stderr ->
# <err_file>, exit status -> $RC.
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

# ── AC1: sprint_proposal_id 7 internal '{"pitch":21}' ────────────────────────
ac_log "AC1: first call with a pitch context appends one sprint proposal"
TAPE_1="$TMP_DIR/tape-1"
mkdir -p "$TAPE_1"
run_sprint "$TAPE_1" "$TMP_DIR/out-1" "$TMP_DIR/err-1" 7 internal '{"pitch":21}'
ac_assert_eq "$RC" "0" \
  "first 7 internal call must return 0 (got $RC): $OUT | $ERR"
[ -n "$OUT" ] || ac_fail "first call must print the proposal id (got empty)"
ac_assert_eq "$(wc -l < "$TAPE_1/tape.jsonl")" "1" \
  "exactly one tape line after the first call (got $(wc -l < "$TAPE_1/tape.jsonl"))"
LINE="$(head -n1 "$TAPE_1/tape.jsonl")"
ac_assert_jq '.loop == "sprint" and .decision == "approved"
    and .ref == "milestone:7" and .context == {"pitch":21}' "$LINE" \
  "record must be an approved sprint proposal whose context is {\"pitch\":21}"
[ -f "$TAPE_1/sprints/7" ] || ac_fail "id file missing after the first call"
ac_assert_eq "$(cat "$TAPE_1/sprints/7")" "$OUT" \
  "id file must hold the printed id (file: $(cat "$TAPE_1/sprints/7"), printed: $OUT)"
ID_7="$OUT"

# ── AC2: a second call with a different context reuses the id ────────────────
ac_log "AC2: a second call ignores CONTEXT_JSON and appends nothing"
run_sprint "$TAPE_1" "$TMP_DIR/out-2" "$TMP_DIR/err-2" 7 internal '{"pitch":99}'
ac_assert_eq "$RC" "0" \
  "second 7 internal call must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$OUT" "$ID_7" \
  "second call must print the same id (got $OUT, want $ID_7)"
ac_assert_eq "$(wc -l < "$TAPE_1/tape.jsonl")" "1" \
  "second call must append nothing (got $(wc -l < "$TAPE_1/tape.jsonl") lines)"
LINE="$(head -n1 "$TAPE_1/tape.jsonl")"
ac_assert_jq '.context == {"pitch":21}' "$LINE" \
  "existing proposal context must stay {\"pitch\":21}"

# ── AC3: sprint_proposal_id 8 deploy — omitted context defaults to {} ────────
ac_log "AC3: omitted CONTEXT_JSON writes context={}"
TAPE_2="$TMP_DIR/tape-2"
mkdir -p "$TAPE_2"
run_sprint "$TAPE_2" "$TMP_DIR/out-3" "$TMP_DIR/err-3" 8 deploy
ac_assert_eq "$RC" "0" \
  "8 deploy must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(wc -l < "$TAPE_2/tape.jsonl")" "1" \
  "exactly one tape line (got $(wc -l < "$TAPE_2/tape.jsonl"))"
LINE="$(head -n1 "$TAPE_2/tape.jsonl")"
ac_assert_jq '.context == {}' "$LINE" \
  "omitted CONTEXT_JSON must write context={}"

# ── AC4: sprint_proposal_id 9 deploy 'not json' — rc 1, nothing written ──────
ac_log "AC4: a non-object context returns 1, appends nothing, writes no id file"
TAPE_3="$TMP_DIR/tape-3"
mkdir -p "$TAPE_3"
run_sprint "$TAPE_3" "$TMP_DIR/out-4" "$TMP_DIR/err-4" 9 deploy 'not json'
ac_assert_eq "$RC" "1" \
  "non-object context must return 1 (got $RC): $OUT | $ERR"
[ -z "$OUT" ] || ac_fail "non-object context must print nothing (got: $OUT)"
[ ! -f "$TAPE_3/tape.jsonl" ] || ac_fail "non-object context must not append a tape line"
[ ! -f "$TAPE_3/sprints/9" ] || ac_fail "non-object context must write no id file"

ac_pass "issue #1888: sprint proposal context from the decided pitch"
