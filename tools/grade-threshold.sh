#!/usr/bin/env bash
# =============================================================================
# tools/grade-threshold.sh — the first grade above 0.5 tells the owner to
# write rejection rules (#2039)
#
# docs/design/proposal-loop.md §3: "Rejecting dangerous actions starts once
# a grade above 0.5 lands (reachable or reached ...). That first grade tells
# you it is time to write rejection rules, and until you write them approval
# stays transparent." Grades reach the tape from tools/sprint-grades.sh
# (#2036) and from the owner's tools/grade.sh; nothing watches them yet.
# This tool reads the tape and queues exactly one notice for the owner
# (lib/notice.sh, #2031) the moment the first grade above 0.5 lands — then
# never again.
#
# Behaviour:
#   * Marker ${TAPE_DIR:-/srv/disinto/tape}/gate/rejection-rules-told: when
#     it exists, exit 0 and print nothing.
#   * Otherwise walk ${TAPE_DIR}/tape.jsonl in tape order for the first
#     record with type == "grade" and a numeric value greater than 0.5.
#     Malformed (torn) lines are skipped, never fatal; a missing tape counts
#     as "no grade".
#   * No such grade: exit 0, nothing queued.
#   * Found: notice_owner names the value, the proposal, the who and the
#     time; only then mkdir -p the gate dir and touch the marker, so a
#     failed queue is retried next run. One log line.
#
# Usage:
#   tools/grade-threshold.sh
#
# Environment (all optional; the test seam):
#   TAPE_DIR      tape directory (default /srv/disinto/tape)
#   NOTICES_DIR   notice queue directory (lib/notice.sh's own default:
#                 <tape>/notices)
#
# Exit codes:
#   0  nothing to tell (marker already there, no grade above 0.5, no tape),
#      or the notice was queued
#   1  jq is missing, or the notice could not be queued
#
# Hermetic: the tape and the notices queue only. No agent, no network, no
# secrets (AD-006). Does not source lib/env.sh: jq and lib/notice.sh are all
# it needs. Tests: tests/acceptance/issue-2039.sh.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# shellcheck source=../lib/notice.sh
source "$REPO_ROOT/lib/notice.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE="${TAPE_DIR}/tape.jsonl"
MARKER="${TAPE_DIR}/gate/rejection-rules-told"

if ! command -v jq >/dev/null 2>&1; then
  echo "grade-threshold: required tool missing: jq" >&2
  exit 1
fi

# Same shape as lib/env.sh log(), without sourcing it (see header).
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-grade-threshold}" "$*"
}

# Told once is told forever: the marker is the whole state (see header).
if [ -e "$MARKER" ]; then
  exit 0
fi

# First grade above 0.5, in tape order. One jq call per line so a torn line
# is skipped rather than fatal (the tape is append-only and half-written rows
# do happen — same policy as tools/sprint-grades.sh).
row=""
if [ -r "$TAPE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    row="$(jq -c -r '
      select(.type == "grade")
      | select(.value | type == "number")
      | select(.value > 0.5)' <<<"$line" 2>/dev/null)" || continue
    if [ -n "$row" ]; then
      break
    fi
  done <"$TAPE"
fi

if [ -z "$row" ]; then
  exit 0
fi

value="$(jq -r '.value' <<<"$row")"
proposal="$(jq -r '.proposal_id // empty' <<<"$row")"
who="$(jq -r '.who // empty' <<<"$row")"
when="$(jq -r '.t // empty' <<<"$row")"

text="A grade above 0.5 is on the tape: ${value} on proposal ${proposal} by ${who} (${when}). Time to write rejection rules for the gate (docs/design/proposal-loop.md §3); approval stays transparent until then."

if ! notice_owner "$text"; then
  log "WARNING: grade ${value} could not be queued for the owner — the notice is retried next run"
  exit 1
fi

# The marker comes only after the queue succeeded (see header): a failed
# notice is retried, and a notice already queued with an unwritable marker
# keeps exit 0 (a rerun may queue a second one).
if ! mkdir -p "${TAPE_DIR}/gate" 2>/dev/null || ! touch "$MARKER" 2>/dev/null; then
  log "WARNING: grade ${value} queued, but the marker ${MARKER} could not be written"
else
  log "told the owner: first grade above 0.5 is ${value} on proposal ${proposal}"
fi
exit 0
