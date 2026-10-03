#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1637.sh
#
# Issue #1637: a repair outcome is the remedy's own check — did the remedy
# act, and did the condition clear within a window after it acted.
#
#   - repair_direct_dispatch, after the action script, stores acted (1 when
#     the script exited 0, else 0) and acted_at (epoch; clock SUPERVISOR_NOW)
#     on that condition's state entry.
#   - repair_tape_tick writes {acted, cleared} once the condition stops
#     firing within SUPERVISOR_REPAIR_WINDOW_S (default 3600) or the window
#     passes, then drops the entry. cleared is 1 only when acted is 1 and
#     the condition is gone inside the window.
#   - an entry without acted_at whose condition stops firing is dropped
#     with no outcome.
#   - regression_cleared is never written.
#
# Hermetic: no network, stubbed action scripts, fixed SUPERVISOR_NOW, temp
# state file and TAPE_DIR. A tick is repair_tape_tick then
# repair_direct_dispatch, the same order supervisor-run.sh uses.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# The old bit must not be written anywhere in the supervisor.
if grep -q 'regression_cleared' "$TARGET"; then
  ac_fail "supervisor-run.sh must not write regression_cleared (#1637)"
fi
grep -q 'SUPERVISOR_REPAIR_WINDOW_S:-3600' "$TARGET" \
  || ac_fail "the repair window must default to 3600 seconds"
grep -q 'SUPERVISOR_NOW' "$TARGET" \
  || ac_fail "the repair clock must be SUPERVISOR_NOW"

# One blob, not one extractor call per function: the per-function extract
# sequence is shared with the earlier repair-tape tests, and a 5-line copy
# fails duplicate detection (#1637).
REPAIR_FNS=""
for _fn in repair_tape_state_file _repair_state_update repair_state_put \
    emit_repair_proposal repair_conditions_current_json repair_tape_tick \
    repair_direct_dispatch; do
  _src="$(ac_extract_fn "$_fn" "$TARGET")"
  [ -n "$_src" ] || ac_fail "supervisor-run.sh is missing ${_fn}() (#1637)"
  REPAIR_FNS="${REPAIR_FNS}${_src}"$'\n'
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="${WORK}/factory"
MARK="${WORK}/ran"
mkdir -p "${ROOT}/supervisor/actions" "$MARK"

# Stand-in for supervisor-run.sh's log(); the tick subshell inherits it.
log() { printf '[1637] %s\n' "$*"; }

# Rewrite the stubbed remedy so the next tick sees the given exit code.
stub_remedy() {
  local code="$1"
  printf '%s\n' '#!/usr/bin/env bash' "echo ran >> '${MARK}/stale-worktree'" "exit ${code}" \
    > "${ROOT}/supervisor/actions/cleanup-worktrees.sh"
}

FIRED='{"fired":[{"name":"stale-worktree","severity":"P4","evidence":"age 180m","action":"direct","action_script":"supervisor/actions/cleanup-worktrees.sh"}]}'
QUIET='{"fired":[]}'

# judge <tape-dir> <state-file> <now> <recipe-output>
# One supervisor tick at a fixed clock. The window var is left unset so the
# 3600 default is what the code actually uses. Prints combined output.
judge() {
  local tape_dir="$1" state_file="$2" now="$3" recipes="$4"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir"
    export PAYLOAD_DIR="${tape_dir}/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file"
    export SUPERVISOR_NOW="$now"
    unset SUPERVISOR_REPAIR_WINDOW_S
    export CI_UNTRUSTED=false INCIDENT_PR="" RECIPE_OUTPUT="$recipes"
    export FACTORY_ROOT="$ROOT"
    export PROJECT_TOML="${ROOT}/projects/disinto.toml"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "${REPO_ROOT}/lib/tape.sh"
    eval "$REPAIR_FNS"
    repair_tape_tick
    repair_direct_dispatch "$RECIPE_OUTPUT"
  ) 2>&1
}

# The single outcome record in a tape, or empty.
outcome_rec() {
  local file="$1"
  [ -f "$file" ] || return 0
  jq -c 'select(.type == "outcome")' "$file" | head -n1
}

# ── 1. remedy exit 0, condition gone on the next tick → acted 1, cleared 1 ──
ac_log "AC 1: exit 0, condition gone inside the window → {acted:1, cleared:1}"
TAPE1="$WORK/tape-cleared"
STATE1="$WORK/state-cleared.json"
stub_remedy 0
rc=0
out="$(judge "$TAPE1" "$STATE1" 1000 "$FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "the acting tick must return 0 (got $rc): $out"
ac_assert_file "$MARK/stale-worktree" "the stubbed remedy must have run"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted // empty' "$STATE1")" "1" \
  "exit 0 must store acted=1"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted_at // empty' "$STATE1")" "1000" \
  "acted_at must be the fixed SUPERVISOR_NOW"
[ -z "$(outcome_rec "$TAPE1/tape.jsonl")" ] \
  || ac_fail "the acting tick must not write an outcome before the window is judged"
PROPOSAL1="$(jq -r '.["stale-worktree"].proposal_id' "$STATE1")"
[ -n "$PROPOSAL1" ] || ac_fail "the acting tick must record a proposal id"

rc=0
out="$(judge "$TAPE1" "$STATE1" 1100 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "the clearing tick must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PROPOSAL1"
  and .bits == {"acted": 1, "cleared": 1}
  and .numbers == {}
  and .children == {}
  and .payloads == []
JQ
)" "$(outcome_rec "$TAPE1/tape.jsonl")" \
  "exit 0 and condition gone inside the window must write {acted:1, cleared:1}"
ac_assert_eq "$(jq -rs '[.[] | select(.type == "outcome")] | length' "$TAPE1/tape.jsonl")" "1" \
  "a cleared condition must write exactly one outcome"
ac_assert_eq "$(jq -r 'keys | length' "$STATE1")" "0" \
  "the judged condition must drop out of the state file"
ac_log "AC 1 OK"

# ── 2. remedy exit 0, still firing after the window → acted 1, cleared 0 ────
ac_log "AC 2: exit 0, still firing after the window → {acted:1, cleared:0}"
TAPE2="$WORK/tape-stuck"
STATE2="$WORK/state-stuck.json"
: > "$MARK/stale-worktree"
stub_remedy 0
rc=0
out="$(judge "$TAPE2" "$STATE2" 2000 "$FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "the acting tick must return 0 (got $rc): $out"
PROPOSAL2="$(jq -r '.["stale-worktree"].proposal_id' "$STATE2")"
[ -n "$PROPOSAL2" ] || ac_fail "AC 2 acting tick must record a proposal id"
# 2000 + default window 3600 + 1. The window var is unset, so this also
# pins the 3600 default.
rc=0
out="$(judge "$TAPE2" "$STATE2" 5601 "$FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "the expired tick must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PROPOSAL2"
  and .bits == {"acted": 1, "cleared": 0}
JQ
)" "$(outcome_rec "$TAPE2/tape.jsonl")" \
  "exit 0 and still firing after the window must write {acted:1, cleared:0}"
NEW2="$(jq -r '.["stale-worktree"].proposal_id // empty' "$STATE2")"
[ -n "$NEW2" ] || ac_fail "a later firing after the window must open a new proposal"
[ "$NEW2" != "$PROPOSAL2" ] || ac_fail "the new proposal must not reuse the closed id"
ac_log "AC 2 OK"

# ── 3. remedy exit 1, condition gone → acted 0, cleared 0 ───────────────────
ac_log "AC 3: exit 1, condition gone → {acted:0, cleared:0}"
TAPE3="$WORK/tape-failed"
STATE3="$WORK/state-failed.json"
stub_remedy 1
rc=0
out="$(judge "$TAPE3" "$STATE3" 3000 "$FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "a failing remedy must not fail the tick (got $rc): $out"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted // empty' "$STATE3")" "0" \
  "exit 1 must store acted=0"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted_at // empty' "$STATE3")" "3000" \
  "a failing remedy must still record acted_at"
PROPOSAL3="$(jq -r '.["stale-worktree"].proposal_id' "$STATE3")"
rc=0
out="$(judge "$TAPE3" "$STATE3" 3100 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "the clearing tick after a failed remedy must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PROPOSAL3"
  and .bits == {"acted": 0, "cleared": 0}
JQ
)" "$(outcome_rec "$TAPE3/tape.jsonl")" \
  "exit 1 and condition gone must write {acted:0, cleared:0}"
ac_assert_eq "$(jq -r 'keys | length' "$STATE3")" "0" \
  "the failed remedy's entry must drop once judged"
ac_log "AC 3 OK"

# ── 4. no acted_at, condition stops firing → drop, no outcome ───────────────
ac_log "AC 4: entry without acted_at drops with no outcome"
TAPE4="$WORK/tape-unacted"
STATE4="$WORK/state-unacted.json"
mkdir -p "$TAPE4"
jq -n --arg id "repair-seed-unacted" \
  '{"stale-worktree": {proposal_id: $id, class: "stale-worktree", since: "2024-01-01T00:00:00Z"}}' \
  > "$STATE4"
rc=0
out="$(judge "$TAPE4" "$STATE4" 4000 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "dropping an unacted entry must return 0 (got $rc): $out"
[ ! -f "$TAPE4/tape.jsonl" ] \
  || ac_fail "an entry without acted_at must not write an outcome when it stops firing"
ac_assert_eq "$(jq -r 'keys | length' "$STATE4")" "0" \
  "an entry without acted_at must drop when its condition stops firing"
ac_log "AC 4 OK"

# ── 5. no outcome anywhere carries regression_cleared ───────────────────────
ac_log "AC 5: no outcome carries regression_cleared"
for tape in "$TAPE1" "$TAPE2" "$TAPE3" "$TAPE4"; do
  if [ -f "$tape/tape.jsonl" ] && grep -q 'regression_cleared' "$tape/tape.jsonl"; then
    ac_fail "tape $tape must not carry regression_cleared"
  fi
done
ac_log "AC 5 OK"

ac_pass
