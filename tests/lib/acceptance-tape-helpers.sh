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
