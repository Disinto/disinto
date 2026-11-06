#!/usr/bin/env bash
# =============================================================================
# planner/in-flight.sh — the planner holds while a sprint is not graded yet
# (#2150)
#
# A filed sprint soaks on the tape until tools/sprint-grades.sh (#2036) writes
# a grade record for it. The claim `can-update-self` follows only once its
# effect is met (docs/design/notes/self-update.md), so while milestone 7 is
# filed and ungraded the ladder still prints `update-self`. Opening a second
# update-self pitch beside a sprint in flight would pitch work already in
# progress.
#
# Function (sourced; called by planner/pitch-or-idle.sh):
#   planner_sprint_in_flight
#     -> the ref (e.g. milestone:7) of the first approved sprint proposal on
#        the tape with no grade record, or nothing. A missing tape prints
#        nothing. An unreadable tape returns 1.
# =============================================================================
set -euo pipefail

# planner_sprint_in_flight — see the file header.
planner_sprint_in_flight() {
  local tape="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"
  [ -f "$tape" ] || return 0
  jq -rs '
    (map(select(.type == "grade") | .proposal_id)) as $graded
    | map(select(.type == "proposal" and .loop == "sprint" and .decision == "approved"))
    | map(select(.id as $id | ($graded | index($id)) == null))
    | .[0].ref // empty' "$tape" || return 1
}
