#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1888.sh
#
# Issue #1888: sprint_proposal_id takes the context of the sprint proposal it
# mints. A decided pitch is an ops-repo PR number; it is recorded on that
# milestone's one sprint proposal as context.pitch.
#
#   sprint_proposal_id MILESTONE_ID CLASS [CONTEXT_JSON]
#     CONTEXT_JSON is a JSON object, default {}. Ignored when the id file
#     already holds an id. A non-object is an append failure: rc 1, no
#     stdout, no id file, no tape line.
#
# Hermetic: no network, no forge, no agent. lib/sprint-tape.sh is sourced
# once; each scenario points TAPE_DIR at its own empty directory. tape.sh
# reads $TAPE_DIR when it appends, not when it is sourced.
#
# Acceptance: `bash tests/acceptance/issue-1888.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq flock
ac_assert_file "$REPO_ROOT/lib/sprint-tape.sh" "sprint-tape helper missing"

# Keep the source-time default off /srv/disinto/tape. Later assignments of
# TAPE_DIR are what the writers see.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export TAPE_DIR="$SCRATCH/unset"
# shellcheck source=../../lib/sprint-tape.sh
source "$REPO_ROOT/lib/sprint-tape.sh"

# invoke DIR ARGS... — call sprint_proposal_id against DIR.
# STATUS is the exit code, PRINTED is stdout, COMPLAINT is stderr.
invoke() {
  local dir="$1"
  shift
  local sink="$SCRATCH/invoke.out" moan="$SCRATCH/invoke.err"
  STATUS=0
  PRINTED=""
  COMPLAINT=""
  TAPE_DIR="$dir"
  sprint_proposal_id "$@" >"$sink" 2>"$moan" || STATUS=$?
  PRINTED="$(cat "$sink")"
  COMPLAINT="$(cat "$moan")"
}

tape_lines() {
  local jsonl="$1/tape.jsonl"
  if [ -f "$jsonl" ]; then
    wc -l < "$jsonl"
  else
    printf '0\n'
  fi
}

first_line() {
  head -n1 "$1/tape.jsonl"
}

# ── AC1: sprint_proposal_id 7 internal '{"pitch":21}' ────────────────────────
ac_log "AC1: pitch context is stored on the minted sprint proposal"
PITCH_DIR="$SCRATCH/with-pitch"
mkdir -p "$PITCH_DIR"
invoke "$PITCH_DIR" 7 internal '{"pitch":21}'
ac_assert_eq "$STATUS" "0" \
  "pitch mint must return 0 (got $STATUS): $PRINTED | $COMPLAINT"
[ -n "$PRINTED" ] || ac_fail "pitch mint printed no proposal id"
ac_assert_eq "$(tape_lines "$PITCH_DIR")" "1" \
  "pitch mint must append one tape line (got $(tape_lines "$PITCH_DIR"))"
ac_assert_jq '.loop == "sprint" and .decision == "approved"
    and .ref == "milestone:7" and .context == {"pitch":21}' \
  "$(first_line "$PITCH_DIR")" \
  "tape line must be an approved sprint proposal with context {\"pitch\":21}"
ac_assert_eq "$(cat "$PITCH_DIR/sprints/7")" "$PRINTED" \
  "id file must hold the printed id"
KEPT_ID="$PRINTED"

# ── AC2: a second call with a different context reuses the id ────────────────
ac_log "AC2: a second call reuses the id and ignores the new context"
invoke "$PITCH_DIR" 7 internal '{"pitch":99}'
ac_assert_eq "$STATUS" "0" \
  "second mint must return 0 (got $STATUS): $PRINTED | $COMPLAINT"
ac_assert_eq "$PRINTED" "$KEPT_ID" \
  "second mint printed $PRINTED, want $KEPT_ID"
ac_assert_eq "$(tape_lines "$PITCH_DIR")" "1" \
  "second mint must not append (got $(tape_lines "$PITCH_DIR") lines)"
ac_assert_jq '.context == {"pitch":21}' "$(first_line "$PITCH_DIR")" \
  "stored context must stay {\"pitch\":21}"

# ── AC3: sprint_proposal_id 8 deploy — omitted context defaults to {} ────────
ac_log "AC3: a two-argument call writes context={}"
BARE_DIR="$SCRATCH/no-context"
mkdir -p "$BARE_DIR"
invoke "$BARE_DIR" 8 deploy
ac_assert_eq "$STATUS" "0" \
  "two-argument mint must return 0 (got $STATUS): $PRINTED | $COMPLAINT"
ac_assert_jq '.context == {}' "$(first_line "$BARE_DIR")" \
  "omitted CONTEXT_JSON must write context={}"

# ── AC4: sprint_proposal_id 9 deploy 'not json' — rc 1, nothing written ──────
ac_log "AC4: a non-object context returns 1 and writes nothing"
BAD_DIR="$SCRATCH/bad-context"
mkdir -p "$BAD_DIR"
invoke "$BAD_DIR" 9 deploy 'not json'
ac_assert_eq "$STATUS" "1" \
  "non-object context must return 1 (got $STATUS): $PRINTED | $COMPLAINT"
[ -z "$PRINTED" ] || ac_fail "non-object context must print nothing (got: $PRINTED)"
ac_assert_eq "$(tape_lines "$BAD_DIR")" "0" \
  "non-object context must add no tape line"
[ ! -e "$BAD_DIR/sprints/9" ] || ac_fail "non-object context must create no id file"

ac_pass "issue #1888: sprint proposal context from the decided pitch"
