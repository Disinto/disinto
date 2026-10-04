#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1702.sh
#
# Issue #1702: a cleared repair outcome that fails to land on the tape must
# stay in the repair state file. emit_repair_proposal already skips the state
# write when the proposal append fails; repair_tape_tick must do the same on
# the close path, or the next tick has nothing to retry and calibration
# treats the proposal as still open.
#
#   1. An unwritable TAPE_DIR while a recorded condition has cleared: the
#      tick returns 0, writes no outcome, and leaves the state entry.
#   2. The same condition against a writable TAPE_DIR appends
#      {acted:1, cleared:1} and drops the entry.
#   3. A transient append failure is not permanent: the entry kept in (1)
#      receives its outcome on the next tick once TAPE_DIR is writable.
#
# Hermetic: no network. The tick is the extracted repair_tape_tick and its
# helpers, run against a temp state file. Clock is SUPERVISOR_NOW.
#
# Acceptance: bash tests/acceptance/issue-1702.sh exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd sha256sum

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# The close path must not document the old drop-on-failure rule.
if grep -q 'A failed outcome append still drops' "$TARGET"; then
  ac_fail "repair_tape_tick must not drop a condition when the outcome append fails (#1702)"
fi

# One blob: a per-function extract sequence copies the earlier repair-tape
# tests and fails the 5-line duplicate detector.
CLOSE_FNS=""
for _fn in repair_tape_state_file _repair_state_update repair_state_put \
    emit_repair_proposal repair_conditions_current_json repair_tape_tick; do
  _src="$(ac_extract_fn "$_fn" "$TARGET")"
  [ -n "$_src" ] || ac_fail "supervisor-run.sh is missing ${_fn}() (#1702)"
  CLOSE_FNS+="${_src}"$'\n'
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stand-in for supervisor-run.sh's log(); the tick subshell inherits it.
log() { printf '[1702] %s\n' "$*"; }

QUIET='{"fired":[]}'
COND="cleanup-locks"
PID="repair-1702-kept"
ACTED_AT=4000
NOW=5000

# seed_cleared <state-file> — one acted condition, inside the window, so a
# quiet tick must try to append {acted:1, cleared:1}.
seed_cleared() {
  jq -n --arg c "$COND" --arg id "$PID" --argjson at "$ACTED_AT" \
    '{($c): {proposal_id: $id, class: $c, since: "2026-04-01T00:00:00Z", acted: 1, acted_at: $at}}' \
    > "$1"
}

# close_one <tape-dir> <state-file>
# One repair_tape_tick at the fixed clock, condition not firing. Prints
# combined output; returns the tick's exit status.
close_one() {
  local tape="$1" state="$2"
  (
    set -euo pipefail
    export TAPE_DIR="$tape"
    export PAYLOAD_DIR="${tape}/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state"
    export SUPERVISOR_NOW="$NOW"
    export SUPERVISOR_REPAIR_WINDOW_S=3600
    export CI_UNTRUSTED=false
    export INCIDENT_PR=""
    export RECIPE_OUTPUT="$QUIET"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$CLOSE_FNS"
    repair_tape_tick
  ) 2>&1
}

# outcome_line <tape.jsonl> — the single outcome record, or empty.
outcome_line() {
  local file="$1"
  [ -f "$file" ] || return 0
  jq -c 'select(.type == "outcome")' "$file"
}

# ── 1. failed append leaves the cleared condition for retry ─────────────────
ac_log "AC 1: unwritable TAPE_DIR leaves the cleared condition in state"
BLOCK="$WORK/not-a-directory"
touch "$BLOCK"
TAPE_FAIL="${BLOCK}/tape"
STATE_FAIL="$WORK/state-kept.json"
seed_cleared "$STATE_FAIL"
BEFORE="$(sha256sum "$STATE_FAIL")"
rc=0
out="$(close_one "$TAPE_FAIL" "$STATE_FAIL")" || rc=$?
ac_assert_eq "$rc" "0" "a failed cleared-outcome append must not fail the tick (got $rc): $out"
case "$out" in
  *"WARNING: tape: failed to append repair outcome"*) ;;
  *) ac_fail "a failed cleared-outcome append must log a tape warning, got: $out" ;;
esac
[ ! -e "$TAPE_FAIL/tape.jsonl" ] \
  || ac_fail "no outcome may be written when TAPE_DIR is unwritable"
ac_assert_eq "$(sha256sum "$STATE_FAIL")" "$BEFORE" \
  "a failed cleared-outcome append must not rewrite the repair state file"
ac_assert_eq "$(jq -r --arg c "$COND" '.[$c].proposal_id // empty' "$STATE_FAIL")" \
  "$PID" \
  "the cleared condition must remain in the state file for the next tick"
ac_log "AC 1 OK"

# ── 2. a successful append still drops the entry ────────────────────────────
ac_log "AC 2: a successful cleared outcome drops the state entry"
TAPE_OK="$WORK/tape-ok"
STATE_OK="$WORK/state-dropped.json"
seed_cleared "$STATE_OK"
rc=0
out="$(close_one "$TAPE_OK" "$STATE_OK")" || rc=$?
ac_assert_eq "$rc" "0" "a successful cleared-outcome append must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PID"
  and .bits == {"acted": 1, "cleared": 1}
JQ
)" "$(outcome_line "$TAPE_OK/tape.jsonl")" \
  "a cleared acted condition must append {acted:1, cleared:1}"
ac_assert_eq "$(jq -r 'keys | length' "$STATE_OK")" "0" \
  "a successful cleared-outcome append must drop the state entry"
ac_log "AC 2 OK"

# ── 3. the kept entry is retryable once the tape is writable again ──────────
ac_log "AC 3: a transient TAPE_DIR failure does not permanently drop the condition"
TAPE_RETRY="$WORK/tape-retry"
rc=0
out="$(close_one "$TAPE_RETRY" "$STATE_FAIL")" || rc=$?
ac_assert_eq "$rc" "0" "the retry tick must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PID"
  and .bits == {"acted": 1, "cleared": 1}
JQ
)" "$(outcome_line "$TAPE_RETRY/tape.jsonl")" \
  "the next tick must append the cleared outcome the failed tick could not"
ac_assert_eq "$(jq -rs '[.[] | select(.type == "outcome")] | length' "$TAPE_RETRY/tape.jsonl")" "1" \
  "the retry must write exactly one outcome"
ac_assert_eq "$(jq -r 'keys | length' "$STATE_FAIL")" "0" \
  "the retried condition must drop only after the outcome lands"
ac_log "AC 3 OK"

ac_pass
