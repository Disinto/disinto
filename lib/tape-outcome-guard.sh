#!/usr/bin/env bash
# tape-outcome-guard.sh — one merged outcome per proposal (#1737)
#
# dev-poll (emit_tape_outcome) and the dev agent (close_dev_tape_outcome)
# both record a merge. Calibration counts outcome records, so a second
# merged line inflates n and counts the proposal twice. Neither writer can
# stop outright: when the other poll merges, or a human does, only the
# remaining writer runs.
#
# tape_has_merged_outcome PROPOSAL_ID
#   return 0 when ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl has a record
#   with type "outcome", that proposal_id, and bits.merged 1 or true.
#   return 1 otherwise, including a missing file or an empty id.
#   Prints nothing. Reads TAPE_DIR at call time. Does not append.
#
# Hermetic: jq only. No network, no forge, no agent.

set -euo pipefail

# tape_has_merged_outcome PROPOSAL_ID — 0 if a merged outcome is already
# on the tape, 1 otherwise. See the file header.
tape_has_merged_outcome() {
  local pid="${1:-}"
  local tape="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"

  if [ -z "$pid" ] || [ ! -f "$tape" ]; then
    return 1
  fi

  # One boolean, not select: jq -e reports the last input, so a later
  # non-match would hide an earlier merged outcome (exit 4). Slurp + any
  # is 0 only when some outcome for this id has bits.merged 1 or true.
  # A bad line or a missing jq falls through to return 1 (do not skip).
  if jq -se --arg pid "$pid" '
      any(.[]; .type == "outcome" and .proposal_id == $pid
               and (.bits.merged == 1 or .bits.merged == true))
    ' "$tape" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
