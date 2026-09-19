#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1408.sh
#
# Issue #1408: when the supervisor fires a recipe remedy or the CI circuit
# breaker writes an incident, supervisor/supervisor-run.sh emits a repair
# proposal record on the tape (lib/tape.sh):
#
#   tape_proposal <id> repair "<recipe name or incident>" "" \
#     "<condition identifier>" \
#     '{"signature":"<code-derived label>","organ":"supervisor"}' \
#     "" "auto" "<ref>"
#
# when a later preflight shows the condition cleared, the open proposal is
# matched with one outcome:
#
#   tape_outcome <proposal-id> '{"regression_cleared":1}' '{}' '{}' '[]'
#
# Code-derived labels only (recipe names, condition identifiers) — no LLM.
# A tape failure warns and continues — the supervisor is never blocked by
# the tape (the emitters are total: every failure path logs and returns 0).
#
# Acceptance (read-only — no live services; the supervisor's emit path is
# exercised in-process by extracting the repair-tape functions from
# supervisor/supervisor-run.sh and running one tick against a synthetic
# incident, per issue-1407):
#   1. A synthetic CI incident (CI_UNTRUSTED=true, incident PR 42) lands one
#      repair proposal line: loop=repair, class=incident,
#      caused_by=ci-incident-pr, context={"signature":"ci-incident-pr",
#      "organ":"supervisor"}, decision=auto, ref=incident-pr-42
#   2. A fired recipe lands a proposal with class=caused_by=<recipe name>;
#      re-ticking while the condition stays open appends nothing
#   3. A later preflight in which the recipe no longer fires appends one
#      outcome with bits={"regression_cleared":1} and the condition drops
#      out of the state file
#   4. An unwritable TAPE_DIR: the tick warns and returns 0 — no record, no
#      state written (the next tick retries the proposal)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# ── 0. wiring: supervisor-run.sh sources the tape lib and runs the tick ────
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "supervisor-run.sh must source lib/tape.sh"

CALL_LINE="$(grep -n '^repair_tape_tick$' "$TARGET" | head -n1 | cut -d: -f1 || true)"
GATE_LINE="$(grep -n '^LLM_REQUIRED=true' "$TARGET" | head -n1 | cut -d: -f1 || true)"
[ -n "$CALL_LINE" ] \
  || ac_fail "supervisor-run.sh must run repair_tape_tick (top-level call)"
[ -n "$GATE_LINE" ] \
  || ac_fail "supervisor-run.sh must keep the LLM escalation gate"
[ "$CALL_LINE" -lt "$GATE_LINE" ] \
  || ac_fail "repair_tape_tick must run after recipe evaluation and before the LLM escalation gate (so both the fast path and the LLM path are covered)"

TICK_SRC="$(ac_extract_fn repair_tape_tick "$TARGET")"
[ -n "$TICK_SRC" ] || ac_fail "could not extract repair_tape_tick() from supervisor-run.sh"
COND_SRC="$(ac_extract_fn repair_conditions_current_json "$TARGET")"
[ -n "$COND_SRC" ] || ac_fail "could not extract repair_conditions_current_json() from supervisor-run.sh"
PROP_SRC="$(ac_extract_fn emit_repair_proposal "$TARGET")"
[ -n "$PROP_SRC" ] || ac_fail "could not extract emit_repair_proposal() from supervisor-run.sh"
STATE_SRC="$(ac_extract_fn repair_state_put "$TARGET")"
[ -n "$STATE_SRC" ] || ac_fail "could not extract repair_state_put() from supervisor-run.sh"
UPD_SRC="$(ac_extract_fn _repair_state_update "$TARGET")"
[ -n "$UPD_SRC" ] || ac_fail "could not extract _repair_state_update() from supervisor-run.sh"
STATEFILE_SRC="$(ac_extract_fn repair_tape_state_file "$TARGET")"
[ -n "$STATEFILE_SRC" ] || ac_fail "could not extract repair_tape_state_file() from supervisor-run.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# The extracted emitters log via log(); subshells inherit this stand-in.
log() { echo "supervisor: $*"; }

# run_tick <tape-dir> <state-file> <ci-untrusted> <incident-pr> <recipe-output>
# Run the supervisor's repair-tape tick in an isolated subshell: source the
# real lib/tape.sh, define the six extracted repair-tape functions, set the
# same variables supervisor-run.sh has at the call site (CI_UNTRUSTED,
# INCIDENT_PR, RECIPE_OUTPUT, TAPE_DIR via env), then run repair_tape_tick
# once — exactly what supervisor-run.sh does between recipe evaluation and
# the LLM escalation gate. Captures combined output; returns the tick's
# exit status.
run_tick() {
  local tape_dir="$1" state_file="$2" ci_untrusted="$3" incident_pr="$4" recipe_output="$5"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$tape_dir/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file"
    export CI_UNTRUSTED="$ci_untrusted" INCIDENT_PR="$incident_pr"
    export RECIPE_OUTPUT="$recipe_output"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$STATEFILE_SRC"
    eval "$UPD_SRC"
    eval "$STATE_SRC"
    eval "$PROP_SRC"
    eval "$COND_SRC"
    eval "$TICK_SRC"
    repair_tape_tick
  ) 2>&1
}

# ── 1. synthetic incident: CI circuit breaker open (incident PR 42) ─────────
TAPE1="$TMP_DIR/tape-incident"
STATE1="$TMP_DIR/state-incident.json"
rc=0
out="$(run_tick "$TAPE1" "$STATE1" "true" "42" '{"fired":[]}')" || rc=$?
ac_assert_eq "$rc" "0" "a repair tick with an open CI incident must return 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "no repair proposal record was appended"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" \
  "a newly fired CI incident must append exactly one repair proposal line"
ac_assert_jq "$(cat <<JQ
.type == "proposal"
  and .loop == "repair"
  and .class == "incident"
  and .caused_by == "ci-incident-pr"
  and .context == {"signature": "ci-incident-pr", "organ": "supervisor"}
  and .decision == "auto"
  and .ref == "incident-pr-42"
  and (.id | length > 0)
  and (.parent | not)
  and (.forecast | not)
JQ
)" "$(head -n 1 "$TAPE1/tape.jsonl")" \
  "line 1 must be the repair proposal for the CI incident"
PROPOSAL_ID="$(jq -r '.id' "$TAPE1/tape.jsonl")"
ac_assert_eq "$(jq -r --arg c ci-incident-pr '.[$c].proposal_id // empty' "$STATE1")" \
  "$PROPOSAL_ID" \
  "the state file must record the open repair condition for the later cleared-outcome pairing"

# ── 2. fired recipe: one proposal per condition, no duplicates while open ───
TAPE2="$TMP_DIR/tape-recipe"
STATE2="$TMP_DIR/state-recipe.json"
RECIPE_FIRED='{"fired":[{"name":"disk-pressure","severity":"P1","evidence":"Disk: 85% used","action":"direct","action_script":"supervisor/actions/fix-disk.sh"}]}'
rc=0
out="$(run_tick "$TAPE2" "$STATE2" "false" "" "$RECIPE_FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "a repair tick with a fired recipe must return 0 (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "1" \
  "a newly fired recipe must append exactly one repair proposal line"
ac_assert_jq "$(cat <<JQ
.type == "proposal"
  and .loop == "repair"
  and .class == "disk-pressure"
  and .caused_by == "disk-pressure"
  and .context == {"signature": "disk-pressure", "organ": "supervisor"}
  and .decision == "auto"
  and .ref == "disk-pressure"
JQ
)" "$(head -n 1 "$TAPE2/tape.jsonl")" \
  "line 1 must be the repair proposal for the fired recipe"
RECIPE_ID="$(jq -r '.id' "$TAPE2/tape.jsonl")"
[ -n "$RECIPE_ID" ] || ac_fail "the recipe repair proposal must carry an id"

# A later tick while the condition stays open must append nothing.
rc=0
out="$(run_tick "$TAPE2" "$STATE2" "false" "" "$RECIPE_FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "a repair tick while the recipe condition stays open must return 0 (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "1" \
  "an already-open repair condition must not get a duplicate proposal"

# ── 3. later preflight: condition cleared → outcome, state drained ──────────
rc=0
out="$(run_tick "$TAPE2" "$STATE2" "false" "" '{"fired":[]}')" || rc=$?
ac_assert_eq "$rc" "0" "a repair tick showing the recipe condition cleared must return 0 (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "2" \
  "a cleared condition must append exactly one outcome line"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$RECIPE_ID"
  and .bits == {"regression_cleared": 1}
  and .numbers == {}
  and .children == {}
  and .payloads == []
JQ
)" "$(sed -n '2p' "$TAPE2/tape.jsonl")" \
  "line 2 must be the outcome with regression_cleared bits for the proposal the fired tick emitted"
ac_assert_eq "$(jq -r 'keys | length' "$STATE2")" "0" \
  "the cleared condition must drop out of the state file"

# ── 4. unwritable TAPE_DIR: warn + continue, no record, no state ────────────
# A directory can never be created under a plain file — mkdir -p must fail,
# so no record can land.
touch "$TMP_DIR/blocker"
TAPE4="$TMP_DIR/blocker/tape"
STATE4="$TMP_DIR/state-blocked.json"
rc=0
out="$(run_tick "$TAPE4" "$STATE4" "true" "7" '{"fired":[]}')" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the supervisor tick (got $rc): $out"
case "$out" in
  *"WARNING: tape"*) ;;
  *) ac_fail "an unwritable TAPE_DIR must log a tape warning, got: $out" ;;
esac
[ ! -f "$TAPE4/tape.jsonl" ] \
  || ac_fail "no tape record may be written when TAPE_DIR is unwritable"
[ ! -f "$STATE4" ] \
  || ac_fail "the state file must not record the condition when the tape append failed (the next tick must retry the proposal)"

ac_pass
