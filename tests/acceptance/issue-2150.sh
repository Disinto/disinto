#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2150.sh — the planner holds while a sprint is not
# graded yet
#
# Issue #2150: planner_pitch_or_idle held only while planner-bot had a pitch
# PR open. A sprint already filed on the tape (an approved `sprint` proposal,
# ref `milestone:<n>`) and still soaking — no `grade` record written by
# tools/sprint-grades.sh (#2036) — must hold the planner too: milestone 7 is
# filed and `ladder_lowest_gap` prints `update-self`, so without the check a
# planner run would open a second update-self pitch beside the sprint in
# flight (docs/design/notes/self-update.md).
#
# planner/in-flight.sh adds planner_sprint_in_flight: it prints the ref of the
# first approved sprint proposal with no grade record, nothing when there is
# none or the tape is missing (rc 0), and returns 1 on an unreadable tape.
#
# Hermetic: tape fixtures in a temp dir, in-process stubs. No forge, no agent.
#
# Run via: bash tests/acceptance/issue-2150.sh
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq

INFLIGHT="$REPO_ROOT/planner/in-flight.sh"
IDLE="$REPO_ROOT/planner/pitch-or-idle.sh"

ac_log "static: in-flight.sh exists, is sourced by pitch-or-idle.sh, docs name it"
ac_assert_file "$INFLIGHT" "planner/in-flight.sh is missing"
bash -n "$INFLIGHT"
bash -n "$IDLE"
grep -qF 'in-flight.sh' "$IDLE" \
  || ac_fail "planner/pitch-or-idle.sh must source planner/in-flight.sh"
grep -qF 'planner_sprint_in_flight printed a ref (#2150)' "$IDLE" \
  || ac_fail "the held header line must name planner_sprint_in_flight (#2150)"
grep -qF 'planner_sprint_in_flight' "$IDLE" \
  || ac_fail "planner_pitch_or_idle must call planner_sprint_in_flight"
DOC="$REPO_ROOT/planner/AGENTS.md"
grep -qF 'It holds while a sprint is not graded yet: an approved sprint proposal on the tape with no grade record (`planner/in-flight.sh`, #2150).' "$DOC" \
  || ac_fail "planner/AGENTS.md must say the run holds while a sprint is not graded yet"

# shellcheck source=../planner/in-flight.sh
source "$INFLIGHT"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
TD="$T/tape"
mkdir -p "$TD"

# write_tape ROW... — one JSON row per argument into $TD/tape.jsonl.
write_tape() {
  : >"$TD/tape.jsonl"
  local row
  for row in "$@"; do
    printf '%s\n' "$row" >>"$TD/tape.jsonl"
  done
}

ac_log "AC1: an approved ungraded sprint proposal prints its ref"
write_tape '{"type":"proposal","id":"a","loop":"sprint","decision":"approved","ref":"milestone:7"}'
OUT="$(TAPE_DIR="$TD" planner_sprint_in_flight)"
ac_assert_eq "$OUT" "milestone:7" "an ungraded approved sprint must print milestone:7 (got '$OUT')"

ac_log "AC2: a grade record for the proposal clears the hold"
write_tape '{"type":"proposal","id":"a","loop":"sprint","decision":"approved","ref":"milestone:7"}' \
           '{"type":"grade","proposal_id":"a","value":0.5}'
RC=0
OUT="$(TAPE_DIR="$TD" planner_sprint_in_flight)" || RC=$?
ac_assert_eq "$RC" "0" "a graded sprint must return 0 (rc=$RC)"
ac_assert_eq "$OUT" "" "a graded sprint must print nothing (got '$OUT')"

ac_log "AC3: a rejected sprint proposal prints nothing"
write_tape '{"type":"proposal","id":"a","loop":"sprint","decision":"rejected","ref":"milestone:7"}'
RC=0
OUT="$(TAPE_DIR="$TD" planner_sprint_in_flight)" || RC=$?
ac_assert_eq "$RC" "0" "a rejected sprint must return 0 (rc=$RC)"
ac_assert_eq "$OUT" "" "a rejected sprint must print nothing (got '$OUT')"

ac_log "AC4: a missing tape prints nothing and returns 0"
RC=0
OUT="$(TAPE_DIR="$T/no-such-tape" planner_sprint_in_flight)" || RC=$?
ac_assert_eq "$RC" "0" "a missing tape must return 0 (rc=$RC)"
ac_assert_eq "$OUT" "" "a missing tape must print nothing (got '$OUT')"

ac_log "AC5: an unreadable tape returns 1"
write_tape 'this line is not json'
RC=0
OUT="$(TAPE_DIR="$TD" planner_sprint_in_flight 2>/dev/null)" || RC=$?
ac_assert_eq "$RC" "1" "a non-JSON tape line must return 1 (rc=$RC)"

ac_log "AC6: with an ungraded sprint on the tape, planner_pitch_or_idle prints held and never opens"
# shellcheck source=../planner/pitch-or-idle.sh
source "$IDLE"
ac_rung_fixture "$T"
write_tape '{"type":"proposal","id":"a","loop":"sprint","decision":"approved","ref":"milestone:7"}'
RC=0
OUT="$(
  STUB_DIR="$T"
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { printf 'update-self\n'; }
  planner_pitch_open() { ac_open_stub "$STUB_DIR" "$@"; }
  TAPE_DIR="$TD" planner_pitch_or_idle
)" || RC=$?
ac_assert_eq "$RC" "0" "the sprint hold must return 0 (rc=$RC)"
ac_assert_eq "$OUT" "held" "an ungraded sprint must print held (got '$OUT')"
if [ -e "$T/open-argc" ]; then
  ac_fail "planner_pitch_or_idle must not call planner_pitch_open while the sprint is in flight"
fi

ac_log "AC7: once the sprint is graded the hold lifts and the rung opens"
write_tape '{"type":"proposal","id":"a","loop":"sprint","decision":"approved","ref":"milestone:7"}' \
           '{"type":"grade","proposal_id":"a","value":0.5}'
OUT="$(
  STUB_DIR="$T"
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { printf 'update-self\n'; }
  planner_pitch_open() { ac_open_stub "$STUB_DIR" "$@"; }
  TAPE_DIR="$TD" planner_pitch_or_idle
)"
ac_assert_eq "$OUT" "opened 9" "a graded sprint must let the rung open (got '$OUT')"
ac_assert_eq "$(sed -n '2p' "$T/open-args")" "update-self" "the opened rung must be update-self"

ac_log "AC8: an empty tape does not hold, and issue-1978 and issue-1334 still pass"
RC=0
OUT="$(TAPE_DIR="$T/empty-tape" planner_sprint_in_flight)" || RC=$?
ac_assert_eq "$RC" "0" "a run with no tape dir must return 0 (rc=$RC)"
bash "$REPO_ROOT/tests/acceptance/issue-1978.sh" >/dev/null
bash "$REPO_ROOT/tests/acceptance/issue-1334.sh" >/dev/null

ac_pass
