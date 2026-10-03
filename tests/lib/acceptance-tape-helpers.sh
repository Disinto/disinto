#!/usr/bin/env bash
# =============================================================================
# tests/lib/acceptance-tape-helpers.sh — shared JSONL-tape read helpers for
# acceptance tests
#
# Sourced by tests/acceptance/issue-<N>.sh that exercise close_dev_tape_outcome()
# / tape_outcome() against a temp TAPE_DIR. These are stream-aware (JSONL)
# helpers for reading the (possibly absent) tape.jsonl — kept in one place so the
# tape tests do not duplicate them.
#
# Usage (after sourcing tests/lib/acceptance-helpers.sh):
#   count_outcomes  <tape_dir>          — number of outcome records
#   first_outcome   <tape_dir> <jq-path> — first outcome's field (e.g. .bits.merged)
#
# Shared by tests/acceptance/issue-1532.sh and tests/acceptance/issue-1616.sh
# (both tests otherwise duplicate the two helpers below).
# =============================================================================

# ac_run_close_subshell <tape_dir> <walk_rc> <reason> <times>
#
# Run close_dev_tape_outcome <times> times in a fresh subshell with the tape env,
# sourcing lib/tape.sh. Inherits the caller's close_dev_tape_outcome() /
# dev_walk_reason_terminal() (eval'd in the test's parent). reason (possibly "")
# seeds _PR_WALK_EXIT_REASON. log() / signature_for() are no-ops in the subshell
# (close_dev_tape_outcome may invoke either). Returns the subshell exit code.
#
# Shared by the close_dev_tape_outcome acceptance tests (issue-1532.sh,
# issue-1705.sh, ...): each test's run_close() then only maps its own argument
# shape to this runner, instead of re-emitting the subshell env.
ac_run_close_subshell() {
  local tape_dir="$1" walk_rc="$2" reason="${3:-}" times="${4:-1}"
  (
    export TAPE_DIR="$tape_dir"
    export PROJECT_NAME="$PROJECT_NAME"
    export ISSUE="$ISSUE_TEST"
    export PR_WALK_RC="$walk_rc"
    export LOGFILE="$TMP_DIR/close.log"
    _DEV_REFUSAL_STATUS=""
    _PR_WALK_EXIT_REASON="$reason"
    _DEV_TAPE_OUTCOME_WRITTEN=0
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    log() { :; }
    signature_for() { :; }
    i=1
    while [ "$i" -le "$times" ]; do
      close_dev_tape_outcome
      i=$(( i + 1 ))
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

# First outcome record's field in the JSONL tape at <tape_dir>/tape.jsonl.
# Args: <tape_dir> <jq-path> (e.g. .bits.merged). Empty string when no
# outcome. Stream-aware (JSONL).
first_outcome() {
  local f="$1/tape.jsonl" p="$2"
  if [ -f "$f" ]; then
    jq -r "select(.type == \"outcome\") | $p" "$f" 2>/dev/null | head -n1
  fi
}
