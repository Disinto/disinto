#!/usr/bin/env bash
# =============================================================================
# tools/grade.sh — one-command human grading of a proposal (#1410)
#
# Appends one grade record to the proposal-loop tape via lib/tape.sh (#1389):
#   {"type":"grade","t","proposal_id","value":<number>,"when","who"}
#
# who    = the invoking user ($USER; falls back to `id -un` when unset)
# when   = at_outcome by default (graded after seeing the outcome);
#          pass at_approval to grade at approval time
#
# The appended line is printed to stdout and nothing else. All errors (usage,
# refusal) go to stderr.
#
# Usage:
#   tools/grade.sh <proposal-id> <float> [at_approval|at_outcome]
#
# Environment:
#   TAPE_DIR  tape directory (default /srv/disinto/tape, from lib/tape.sh)
#   USER      the grading user recorded as `who`
#
# Exit codes:
#   0    grade appended and printed
#   64   usage error: missing args, non-float value, unknown `when`
#   1/2  propagated from lib/tape.sh (refused / usage)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"

usage() {
  echo "usage: $(basename "$0") <proposal-id> <float> [at_approval|at_outcome]" >&2
}

pid="${1:-}"
value="${2:-}"
when="${3:-at_outcome}"

if [ -z "$pid" ] || [ -z "$value" ]; then
  usage
  exit 64
fi
if ! [[ "$value" =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]; then
  echo "grade: value must be a float (got '$value')" >&2
  usage
  exit 64
fi
case "$when" in
  at_approval|at_outcome) ;;
  *)
    echo "grade: when must be at_approval|at_outcome (got '$when')" >&2
    usage
    exit 64
    ;;
esac

who="${USER:-$(id -un)}"

# tape_grade echoes the exact record it appended (built in memory, not
# re-read from the file), so the printed line is always ours even if a
# concurrent writer interleaves its own append.
tape_grade "$pid" "$value" "$when" "$who" || exit "$?"
