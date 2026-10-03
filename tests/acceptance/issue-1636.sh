#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1636.sh
#
# Issue #1636: a repair proposal is written only when a direct remedy runs.
# A condition that no remedy acts on is a monitor, not a proposal.
#
#   - repair_tape_tick no longer creates proposals for new conditions. It
#     still closes conditions that already have a proposal.
#   - repair_direct_dispatch, before running a direct recipe's action_script,
#     calls emit_repair_proposal (class = recipe name) when the state file
#     has no open proposal for that recipe, so the run that follows pairs
#     with it.
#   - emit_repair_proposal passes an empty caused_by. The condition stays
#     in context.signature.
#   - incident recipes (pr-stale) and the CI incident condition write none.
#
# A tick here is what supervisor-run.sh does between recipe evaluation and
# the fast path: repair_tape_tick, then repair_direct_dispatch. No network.
# Action scripts are stubbed. SUPERVISOR_REPAIR_STATE_FILE and TAPE_DIR
# live in a temp dir.
#
# Acceptance:
#   1. A tick where only pr-stale (action incident) fires writes no proposal
#   2. A tick where stale-worktree (action direct, stubbed script) fires
#      writes one repair proposal without caused_by, then an open and a
#      closing run under it
#   3. A second tick with the same recipe still firing writes no second
#      proposal
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# ── wiring: the tick must not emit; dispatch must, with an empty caused_by ──
TICK_SRC="$(ac_extract_fn repair_tape_tick "$TARGET")"
[ -n "$TICK_SRC" ] || ac_fail "could not extract repair_tape_tick() from supervisor-run.sh"
if printf '%s\n' "$TICK_SRC" | grep -q 'emit_repair_proposal'; then
  ac_fail "repair_tape_tick must not create repair proposals (#1636)"
fi
DISPATCH_SRC="$(ac_extract_fn repair_direct_dispatch "$TARGET")"
[ -n "$DISPATCH_SRC" ] || ac_fail "could not extract repair_direct_dispatch() from supervisor-run.sh"
printf '%s\n' "$DISPATCH_SRC" | grep -q 'emit_repair_proposal' \
  || ac_fail "repair_direct_dispatch must emit a repair proposal before running a direct script"
PROP_SRC="$(ac_extract_fn emit_repair_proposal "$TARGET")"
[ -n "$PROP_SRC" ] || ac_fail "could not extract emit_repair_proposal() from supervisor-run.sh"
# shellcheck disable=SC2016  # pattern is a literal source snippet, not an expansion
if printf '%s\n' "$PROP_SRC" | grep -q 'tape_proposal "$id" repair "$class" "" "$condition"'; then
  ac_fail "emit_repair_proposal must not pass the condition name as caused_by"
fi
COND_SRC="$(ac_extract_fn repair_conditions_current_json "$TARGET")"
[ -n "$COND_SRC" ] || ac_fail "could not extract repair_conditions_current_json() from supervisor-run.sh"
STATE_SRC="$(ac_extract_fn repair_state_put "$TARGET")"
[ -n "$STATE_SRC" ] || ac_fail "could not extract repair_state_put() from supervisor-run.sh"
UPD_SRC="$(ac_extract_fn _repair_state_update "$TARGET")"
[ -n "$UPD_SRC" ] || ac_fail "could not extract _repair_state_update() from supervisor-run.sh"
STATEFILE_SRC="$(ac_extract_fn repair_tape_state_file "$TARGET")"
[ -n "$STATEFILE_SRC" ] || ac_fail "could not extract repair_tape_state_file() from supervisor-run.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FACTORY_ROOT="$TMP_DIR/factory"
MARKER_DIR="$TMP_DIR/markers"
mkdir -p "$FACTORY_ROOT/supervisor/actions" "$MARKER_DIR"

# Stand-in for supervisor-run.sh's log() (inherited by the tick subshells).
log() { printf 'supervisor: %s\n' "$*"; }

# Stub the stale-worktree action script. It records that it ran and exits 0.
cat > "$FACTORY_ROOT/supervisor/actions/cleanup-worktrees.sh" <<EOF
#!/usr/bin/env bash
echo "ran" >> "${MARKER_DIR}/stale-worktree"
exit 0
EOF

# run_tick <tape-dir> <state-file> <recipe-output>
# One supervisor tick: repair_tape_tick, then repair_direct_dispatch, the
# same order supervisor-run.sh uses on the fast path. Prints combined
# output; returns the tick's exit status.
run_tick() {
  local tape_dir="$1" state_file="$2" recipe_output="$3"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$tape_dir/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file"
    export CI_UNTRUSTED="false" INCIDENT_PR=""
    export RECIPE_OUTPUT="$recipe_output"
    export FACTORY_ROOT="$FACTORY_ROOT"
    export PROJECT_TOML="$FACTORY_ROOT/projects/disinto.toml"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$STATEFILE_SRC"
    eval "$UPD_SRC"
    eval "$STATE_SRC"
    eval "$PROP_SRC"
    eval "$COND_SRC"
    eval "$TICK_SRC"
    eval "$DISPATCH_SRC"
    repair_tape_tick
    repair_direct_dispatch "$RECIPE_OUTPUT"
  ) 2>&1
}

proposal_count() {
  local file="$1"
  if [ -f "$file" ]; then
    jq -rs '[.[] | select(.type == "proposal")] | length' "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# ── 1. only pr-stale (action incident) fires → no proposal ──────────────────
TAPE1="$TMP_DIR/tape-incident"
STATE1="$TMP_DIR/state-incident.json"
PR_STALE='{"fired":[{"name":"pr-stale","severity":"P3","evidence":"Stale PRs: 2","action":"incident"}]}'
rc=0
out="$(run_tick "$TAPE1" "$STATE1" "$PR_STALE")" || rc=$?
ac_assert_eq "$rc" "0" "an incident-only tick must return 0 (got $rc): $out"
ac_assert_eq "$(proposal_count "$TAPE1/tape.jsonl")" "0" \
  "a tick where only pr-stale fires must write no repair proposal"
[ ! -f "$STATE1" ] \
  || ac_fail "an incident recipe must not record a repair condition"

# ── 2. stale-worktree (action direct, stubbed) → one proposal, then runs ────
TAPE2="$TMP_DIR/tape-direct"
STATE2="$TMP_DIR/state-direct.json"
STALE_WT='{"fired":[{"name":"stale-worktree","severity":"P4","evidence":"worktree age 180m","action":"direct","action_script":"supervisor/actions/cleanup-worktrees.sh"}]}'
rc=0
out="$(run_tick "$TAPE2" "$STATE2" "$STALE_WT")" || rc=$?
ac_assert_eq "$rc" "0" "a direct-remedy tick must return 0 (got $rc): $out"
ac_assert_file "$MARKER_DIR/stale-worktree" \
  "the stubbed stale-worktree script must have run: $out"
ac_assert_file "$TAPE2/tape.jsonl" "the direct-remedy tick must write a tape"
ac_assert_eq "$(proposal_count "$TAPE2/tape.jsonl")" "1" \
  "a direct remedy with no open proposal must write exactly one repair proposal"

prop_rec="$(jq -c 'select(.type == "proposal")' "$TAPE2/tape.jsonl" | head -n1)"
ac_assert_jq "$(cat <<'JQ'
.type == "proposal"
  and .loop == "repair"
  and .class == "stale-worktree"
  and (.caused_by | not)
  and .context == {"signature": "stale-worktree", "organ": "supervisor"}
  and .decision == "auto"
  and .ref == "stale-worktree"
  and (.id | length > 0)
  and (.parent | not)
  and (.forecast | not)
JQ
)" "$prop_rec" \
  "the proposal must name the recipe, keep the condition in context.signature, and carry no caused_by"
PROPOSAL_ID="$(jq -r '.id' <<< "$prop_rec")"

open_rec="$(jq -c --arg p "$PROPOSAL_ID" \
  'select(.type == "run" and .proposal_id == $p and .status == null)' \
  "$TAPE2/tape.jsonl" | head -n1)"
ac_assert_jq '
  .type == "run" and .organ == "supervisor" and .agent == "bash"
  and .attempts == 1 and .cost == {}
  and .ended == null and .status == null
' "$open_rec" "the proposal must be followed by an open run under it"
closed_rec="$(jq -c --arg p "$PROPOSAL_ID" \
  'select(.type == "run" and .proposal_id == $p and .status != null)' \
  "$TAPE2/tape.jsonl" | head -n1)"
ac_assert_jq '
  .type == "run" and .organ == "supervisor" and .agent == "bash"
  and .attempts == 1 and .status == "completed"
  and (.cost.duration_s | type == "number") and (.cost.duration_s >= 0)
' "$closed_rec" "the proposal must be followed by a closing run under it"
ac_assert_eq "$(jq -r --arg c stale-worktree '.[$c].proposal_id // empty' "$STATE2")" \
  "$PROPOSAL_ID" \
  "the state file must record the open proposal so a later tick does not emit another"

# ── 3. same recipe still firing → no second proposal ────────────────────────
rc=0
out="$(run_tick "$TAPE2" "$STATE2" "$STALE_WT")" || rc=$?
ac_assert_eq "$rc" "0" "a second tick with the recipe still firing must return 0 (got $rc): $out"
ac_assert_eq "$(proposal_count "$TAPE2/tape.jsonl")" "1" \
  "a second tick with the same recipe still firing must write no second proposal"
ac_assert_eq "$(jq -r --arg c stale-worktree '.[$c].proposal_id // empty' "$STATE2")" \
  "$PROPOSAL_ID" \
  "the open proposal id must be unchanged on the second tick"

ac_pass
