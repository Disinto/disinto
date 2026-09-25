#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1533.sh
#
# Issue #1533: supervisor/supervisor-run.sh's fast-path direct-action loop ran
# the fired `action_script` recipes but wrote no tape record — "the pair says
# the symptom went away. It does not say which script ran."
#
# The fix (repair_direct_dispatch, #1533) runs each real direct-action script
# AND writes a paired tape run under the recipe's repair proposal id (the
# condition registered by the repair tape, #1408):
#
#   1. open   tape_run  (attempts=1, cost {}, organ=supervisor, agent=bash)
#   2. script = $FACTORY_ROOT/<action_script> "$PROJECT_TOML" "$evidence"
#   3. close  tape_run  (cost {"duration_s":N}, status=completed|failed)
#
# Rules (per the issue):
#   - a missing proposal id -> warn, still run the script, write no tape line
#   - an unwritable $TAPE_DIR -> warn, still run the script, return 0
#   - a non-zero script exit -> closing run is `failed`, never aborts the tick
#   - no tape_outcome is ever written (run status lives on the run record)
#   - dispatch is wired only on the fast path (the LLM path is untouched)
#
# The dispatch is exercised in-process: extract repair_direct_dispatch() and
# repair_tape_state_file() from supervisor/supervisor-run.sh and run one tick
# against a synthetic fired-recipe list, per the #1408 tape tests.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# ── 0. wiring: fast path calls repair_direct_dispatch; bare loop is gone
# ─────────────────────────────────────────────────────────────────────────────
grep -qF 'repair_direct_dispatch "$RECIPE_OUTPUT"' "$TARGET" \
  || ac_fail 'fast path must call repair_direct_dispatch "$RECIPE_OUTPUT"'
DISPATCH_CALLS="$(grep -cF 'repair_direct_dispatch "$RECIPE_OUTPUT"' "$TARGET" || true)"
[ "$DISPATCH_CALLS" -eq 1 ] \
  || ac_fail "repair_direct_dispatch must be invoked exactly once (fast path); got $DISPATCH_CALLS"
if grep -qF '_script _evidence' "$TARGET"; then
  ac_fail "the bare direct-action while loop must have been replaced by repair_direct_dispatch"
fi

# ── extract the functions we need to run the dispatch in-process ────────────
DISPATCH_SRC="$(ac_extract_fn repair_direct_dispatch "$TARGET")"
[ -n "$DISPATCH_SRC" ] || ac_fail "could not extract repair_direct_dispatch() from supervisor-run.sh"
STATEFILE_SRC="$(ac_extract_fn repair_tape_state_file "$TARGET")"
[ -n "$STATEFILE_SRC" ] || ac_fail "could not extract repair_tape_state_file() from supervisor-run.sh"

# ── harness: synthetic factory root; run the dispatch in an isolated subshell
# ─────────────────────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FACTORY_ROOT="$TMP_DIR/factory"
MARKER_DIR="$TMP_DIR/markers"
mkdir -p "$FACTORY_ROOT/supervisor/actions" "$MARKER_DIR"

# Stand-in for supervisor-run.sh's log() (inherited by the run subshells).
log() { printf 'supervisor: %s\n' "$*"; }

# Action script that appends to a baked marker path and exits with EXIT_CODE.
write_action_script() {
  local marker="$1" exit_code="$2"
  cat > "$FACTORY_ROOT/supervisor/actions/close-stuck-pr.sh" <<EOF
#!/usr/bin/env bash
echo "ran" >> "${MARKER_DIR}/${marker}"
exit ${exit_code}
EOF
}

# Repair state file: { <condition>: {proposal_id, class, since} }.
write_state_file() {
  local state_file="$1" condition="$2" proposal_id="$3"
  jq -cn --arg c "$condition" --arg id "$proposal_id" \
    --arg t "2024-01-01T00:00:00Z" \
    '({} | .[$c] = {proposal_id: $id, class: $c, since: $t})' \
    > "$state_file"
}

# Recipe JSON for one fired recipe.
fired_recipe_json() {
  local name="$1" evidence="$2"
  jq -cn --arg n "$name" --arg e "$evidence" \
    '{"fired": [{"name": $n, "severity": "P3", "evidence": $e, "action": "direct", "action_script": "supervisor/actions/close-stuck-pr.sh"}]}'
}

# Run the extracted dispatch in an isolated subshell, exactly as the fast path
# does: source lib/tape.sh, eval the extracted state-file + dispatch functions,
# call repair_direct_dispatch once. Prints combined output; returns its rc.
run_dispatch() {
  local tape_dir="$1" state_file="$2" recipe_output="$3"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$tape_dir/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file"
    export FACTORY_ROOT="$FACTORY_ROOT"
    export PROJECT_TOML="$FACTORY_ROOT/projects/disinto.toml"
    source "$REPO_ROOT/lib/tape.sh"
    eval "$STATEFILE_SRC"
    eval "$DISPATCH_SRC"
    repair_direct_dispatch "$recipe_output"
  ) 2>&1
}

# Count run records on a proposal id in a tape file (0 if the file is absent).
run_count() {
  local file="$1" prop="$2"
  if [ -f "$file" ]; then
    jq -rs --arg p "$prop" '[.[] | select(.type == "run" and .proposal_id == $p)] | length' \
      "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Select the open (status null) or closed (status set) run record for a
# proposal id; one line, or empty.
select_run() {
  local file="$1" prop="$2" kind="$3"
  [ -f "$file" ] || return
  local sel
  case "$kind" in
    open)   sel='select(.type == "run" and .proposal_id == $p and .status == null)' ;;
    closed) sel='select(.type == "run" and .proposal_id == $p and .status != null)' ;;
    *)      return ;;
  esac
  jq -c --arg p "$prop" "$sel" "$file" 2>/dev/null | head -n1
}

# ── 1. present proposal + script exits 0 -> two completed run lines, no outcome
# ─────────────────────────────────────────────────────────────────────────────
TAPE1="$TMP_DIR/tape-1"; mkdir -p "$TMP_DIR/tape-1"
STATE1="$TMP_DIR/state-1.json"
write_state_file "$STATE1" close-stuck-pr PROP1
RECIPE1="$(fired_recipe_json close-stuck-pr "Stuck PRs: 1 (threshold: >0)")"
write_action_script a 0

rc=0
out="$(run_dispatch "$TAPE1" "$STATE1" "$RECIPE1")" || rc=$?
ac_assert_eq "$rc" "0" "present proposal + exit 0 must return 0 (got $rc): $out"
ac_assert_file "$MARKER_DIR/a" "the direct script must have run (marker a missing): $out"

ac_assert_eq "$(run_count "$TAPE1/tape.jsonl" "PROP1")" "2" "exactly two tape runs on PROP1"
ocount="$(jq -rs '[.[] | select(.type == "outcome")] | length' "$TAPE1/tape.jsonl" 2>/dev/null || echo 0)"
ac_assert_eq "$ocount" "0" "no tape_outcome line"

open_rec="$(select_run "$TAPE1/tape.jsonl" "PROP1" open)"
ac_assert_jq '
  .type == "run" and .proposal_id == "PROP1"
  and .organ == "supervisor" and .agent == "bash"
  and .attempts == 1 and .cost == {}
  and .ended == null and .status == null
' "$open_rec" "record 1 must be the open run record"
closed_rec="$(select_run "$TAPE1/tape.jsonl" "PROP1" closed)"
ac_assert_jq '
  .type == "run" and .proposal_id == "PROP1"
  and .organ == "supervisor" and .agent == "bash"
  and .attempts == 1 and .status == "completed"
  and (.cost.duration_s | type == "number") and (.cost.duration_s >= 0)
' "$closed_rec" "record 2 must be the completed closing run"

# ── 2. present proposal + script exits 3 -> failed closing run, rc 0, ran
# ─────────────────────────────────────────────────────────────────────────────
TAPE2="$TMP_DIR/tape-2"; mkdir -p "$TMP_DIR/tape-2"
STATE2="$TMP_DIR/state-2.json"
write_state_file "$STATE2" close-stuck-pr PROP2
RECIPE2="$(fired_recipe_json close-stuck-pr "Stuck PRs: 1 (threshold: >0)")"
write_action_script b 3

rc=0
out="$(run_dispatch "$TAPE2" "$STATE2" "$RECIPE2")" || rc=$?
ac_assert_eq "$rc" "0" "present proposal + exit 3 must return 0 (got $rc): $out"
ac_assert_file "$MARKER_DIR/b" "the direct script must have run despite rc 3 (marker b missing): $out"

ac_assert_eq "$(run_count "$TAPE2/tape.jsonl" "PROP2")" "2" "exactly two tape runs on PROP2"
closed_rec="$(select_run "$TAPE2/tape.jsonl" "PROP2" closed)"
ac_assert_jq '
  .type == "run" and .proposal_id == "PROP2"
  and .organ == "supervisor" and .agent == "bash"
  and .attempts == 1 and .status == "failed"
  and (.cost.duration_s | type == "number") and (.cost.duration_s >= 0)
' "$closed_rec" "closing run must have status failed on exit 3"

# ── 3. recipe name absent from state -> script ran, no run line, rc 0
# ─────────────────────────────────────────────────────────────────────────────
TAPE3="$TMP_DIR/tape-3"; mkdir -p "$TMP_DIR/tape-3"
STATE3="$TMP_DIR/state-3.json"
# close-stuck-pr registered (PROP3), but the recipe that fires is ghost-recipe.
write_state_file "$STATE3" close-stuck-pr PROP3
RECIPE3="$(fired_recipe_json ghost-recipe "Ghost condition")"
write_action_script c 0

rc=0
out="$(run_dispatch "$TAPE3" "$STATE3" "$RECIPE3")" || rc=$?
ac_assert_eq "$rc" "0" "absent proposal + exit 0 must return 0 (got $rc): $out"
ac_assert_file "$MARKER_DIR/c" "the script must still run when no proposal is registered (marker c missing): $out"
ac_assert_eq "$(run_count "$TAPE3/tape.jsonl" "ghost-recipe")" "0" \
  "no tape run for a recipe absent from the repair state"
case "$out" in
  *"no repair proposal"*) ;;
  *) ac_fail "expected a 'no repair proposal' warning for the absent recipe: $out" ;;
esac

# ── 4. unwritable TAPE_DIR -> script ran, return 0
# ─────────────────────────────────────────────────────────────────────────────
# A directory can never be created under a plain file — mkdir -p must fail, so
# no record can land, yet the script still runs and the dispatch returns 0.
touch "$TMP_DIR/blocker"
TAPE4="$TMP_DIR/blocker/tape"
STATE4="$TMP_DIR/state-4.json"
write_state_file "$STATE4" close-stuck-pr PROP4
RECIPE4="$(fired_recipe_json close-stuck-pr "Stuck PRs: 1 (threshold: >0)")"
write_action_script d 0

rc=0
out="$(run_dispatch "$TAPE4" "$STATE4" "$RECIPE4")" || rc=$?
ac_assert_eq "$rc" "0" "unwritable TAPE_DIR must return 0 (got $rc): $out"
ac_assert_file "$MARKER_DIR/d" "the direct script must still run with an unwritable TAPE_DIR (marker d missing): $out"
ac_assert_eq "$(run_count "$TAPE4/tape.jsonl" "PROP4")" "0" "no tape run when TAPE_DIR is unwritable"
case "$out" in
  *"WARNING: tape"*) ;;
  *) ac_fail "expected tape WARNINGs for the unwritable TAPE_DIR: $out" ;;
esac

ac_pass
