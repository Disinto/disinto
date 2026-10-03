#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1638.sh
#
# Issue #1638: an LLM escalation is a diagnose repair proposal.
#
# When the escalation gate runs a session it writes one repair proposal
# (class diagnose, empty caused_by, context {organ, conditions}), exports
# that id as TAPE_PROPOSAL_ID before the session, and after the session
# records state entry diagnose-<id> (acted/acted_at). The #1637 tick writes
# the outcome; the entry is no longer firing when none of its conditions is.
# A tick that does not escalate writes no diagnose proposal.
#
# Hermetic: no network. The session is a stubbed agent_run; the gate is the
# extracted escalation_off. Temp state file and TAPE_DIR.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
DOCS="$REPO_ROOT/supervisor/AGENTS.md"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"
ac_assert_file "$DOCS" "supervisor/AGENTS.md must exist"

DOC_SENTENCE='When the LLM escalation gate runs a session (`SUPERVISOR_LLM_ESCALATION=on`, #1681), it first writes a `diagnose` repair proposal for the fired conditions and exports its id as `TAPE_PROPOSAL_ID`; the tick logic of #1637 writes its outcome (#1638).'
grep -qF "$DOC_SENTENCE" "$DOCS" \
  || ac_fail "supervisor/AGENTS.md must record the diagnose-proposal sentence (#1638)"

# The escalation call is top-level and only reachable after the fast path
# has already exited — a tick that does not escalate never reaches it.
CALL_LINE="$(grep -n '^diagnose_escalation$' "$TARGET" | head -n1 | cut -d: -f1 || true)"
FAST_LINE="$(grep -n 'Supervisor run done (fast path)' "$TARGET" | head -n1 | cut -d: -f1 || true)"
[ -n "$CALL_LINE" ] || ac_fail "the LLM path must call diagnose_escalation"
[ -n "$FAST_LINE" ] || ac_fail "the fast path exit marker is missing"
[ "$CALL_LINE" -gt "$FAST_LINE" ] \
  || ac_fail "diagnose_escalation (line $CALL_LINE) must run only after the fast path has exited (line $FAST_LINE)"
CALLS="$(grep -c '^diagnose_escalation$' "$TARGET" || true)"
[ "$CALLS" -eq 1 ] || ac_fail "diagnose_escalation must be invoked once (got $CALLS)"

# Proposal export precedes the session open, and the state entry follows
# the session close, inside the escalation function.
ESC_BODY="$(ac_extract_fn diagnose_escalation "$TARGET")"
[ -n "$ESC_BODY" ] || ac_fail "could not extract diagnose_escalation()"
EMIT_BODY="$(ac_extract_fn emit_diagnose_proposal "$TARGET")"
[ -n "$EMIT_BODY" ] || ac_fail "could not extract emit_diagnose_proposal()"
printf '%s\n' "$EMIT_BODY" | grep -qF 'export TAPE_PROPOSAL_ID=' \
  || ac_fail "emit_diagnose_proposal must export TAPE_PROPOSAL_ID"
prev=0
for needle in emit_diagnose_proposal 'formula_session_start "supervisor"' \
    formula_session_end repair_diagnose_record; do
  line="$(printf '%s\n' "$ESC_BODY" | grep -nF "$needle" | head -n1 | cut -d: -f1 || true)"
  [ -n "$line" ] || ac_fail "diagnose_escalation is missing: $needle"
  [ "$line" -gt "$prev" ] || ac_fail "diagnose_escalation: $needle is out of order"
  prev="$line"
done

FNS=""
for _fn in repair_tape_state_file _repair_state_update repair_state_put \
    emit_repair_proposal repair_conditions_current_json repair_tape_tick \
    repair_direct_dispatch diagnose_conditions_json emit_diagnose_proposal \
    repair_diagnose_record diagnose_escalation escalation_off; do
  _src="$(ac_extract_fn "$_fn" "$TARGET")"
  [ -n "$_src" ] || ac_fail "supervisor-run.sh is missing ${_fn}() (#1638)"
  FNS="${FNS}${_src}"$'\n'
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIRED='{"fired":[{"name":"pr-stale","severity":"P3","evidence":"Open PRs: 3","action":"incident","action_script":"__MISSING__"}]}'
QUIET='{"fired":[]}'

# gate_keeps_session <recipe-json> <on|off>
# Stub of the escalation gate. Returns 0 when that gate would run the session
# (escalation_off returns 1), 1 when it would take the bash fast path.
gate_keeps_session() {
  local recipes="$1" mode="$2"
  (
    if [ "$mode" = "on" ]; then
      export SUPERVISOR_LLM_ESCALATION=on
    else
      unset SUPERVISOR_LLM_ESCALATION
    fi
    log() { :; }
    eval "$FNS"
    if escalation_off "$recipes"; then
      exit 1
    fi
    exit 0
  ) >/dev/null 2>&1
}

# escalate <tape-dir> <state-file> <now> <recipes> <session-rc>
# One stubbed escalation: real formula session, stubbed agent_run.
escalate() {
  local tape_dir="$1" state_file="$2" now="$3" recipes="$4" session_rc="$5"
  (
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="${tape_dir}/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file" SUPERVISOR_NOW="$now"
    export CI_UNTRUSTED=false RECIPE_OUTPUT="$recipes"
    export WORKTREE="${tape_dir}/wt" PROMPT="stubbed-session"
    unset SUPERVISOR_REPAIR_WINDOW_S TAPE_PROPOSAL_ID
    set -euo pipefail
    log() { printf '[1638] %s\n' "$*"; }
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/formula-session.sh"
    agent_run() { return "$session_rc"; }
    eval "$FNS"
    diagnose_escalation
  ) 2>&1
}

# judge <tape-dir> <state-file> <now> <recipes>
# A later tick. Does not escalate.
judge() {
  local tape_dir="$1" state_file="$2" now="$3" recipes="$4"
  (
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="${tape_dir}/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file" SUPERVISOR_NOW="$now"
    export CI_UNTRUSTED=false RECIPE_OUTPUT="$recipes"
    export FACTORY_ROOT="${WORK}/no-escalation" PROJECT_TOML="${WORK}/no-escalation/p.toml"
    unset SUPERVISOR_REPAIR_WINDOW_S
    set -euo pipefail
    log() { printf '[1638-tick] %s\n' "$*"; }
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    eval "$FNS"
    repair_tape_tick
    repair_direct_dispatch "$RECIPE_OUTPUT"
  ) 2>&1
}

diagnose_count() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf '0'
    return 0
  fi
  jq -s '[.[] | select(.type == "proposal" and .class == "diagnose")] | length' "$file"
}

# ── 1. gate on + stubbed session → one diagnose proposal, run carries id ──
ac_log "AC 1: stubbed escalation writes one diagnose proposal; the run carries its id"
if gate_keeps_session "$FIRED" on; then
  :
else
  ac_fail "SUPERVISOR_LLM_ESCALATION=on must keep the session (gate stub)"
fi
TAPE1="$WORK/tape-on"
STATE1="$WORK/state-on.json"
rc=0
out="$(escalate "$TAPE1" "$STATE1" 1000 "$FIRED" 0)" || rc=$?
ac_assert_eq "$rc" "0" "a stubbed escalation must return 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "the escalation must append a tape record"
ac_assert_eq "$(diagnose_count "$TAPE1/tape.jsonl")" "1" \
  "a stubbed escalation must write exactly one diagnose proposal"
PROPOSAL1="$(jq -r 'select(.type == "proposal" and .class == "diagnose") | .id' "$TAPE1/tape.jsonl")"
[ -n "$PROPOSAL1" ] || ac_fail "the diagnose proposal must have an id"
ac_assert_jq "$(cat <<JQ
.type == "proposal"
  and .loop == "repair"
  and .class == "diagnose"
  and (.caused_by | not)
  and .context == {"organ": "supervisor", "conditions": ["pr-stale"]}
JQ
)" "$(jq -c 'select(.type == "proposal")' "$TAPE1/tape.jsonl")" \
  "the diagnose proposal must name the fired conditions and carry no caused_by"
RUN_IDS="$(jq -sr '[.[] | select(.type == "run") | .proposal_id] | unique | .[0] // empty' "$TAPE1/tape.jsonl")"
ac_assert_eq "$RUN_IDS" "$PROPOSAL1" \
  "the session run must carry the diagnose proposal id"
ac_assert_eq "$(jq -sr '[.[] | select(.type == "run")] | length' "$TAPE1/tape.jsonl")" "2" \
  "the session must append an open run and a closing run"
ac_assert_eq "$(jq -r --arg k "diagnose-${PROPOSAL1}" '.[$k].acted // empty' "$STATE1")" "1" \
  "a session that exited 0 must store acted=1 on diagnose-<id>"
ac_assert_eq "$(jq -r --arg k "diagnose-${PROPOSAL1}" '.[$k].acted_at // empty' "$STATE1")" "1000" \
  "acted_at must be the fixed SUPERVISOR_NOW"
ac_assert_eq "$(jq -c --arg k "diagnose-${PROPOSAL1}" '.[$k].conditions' "$STATE1")" '["pr-stale"]' \
  "the state entry must keep the fired condition names"
ac_log "AC 1 OK"

# ── 2. still firing → not cleared; gone on the next tick → acted 1, cleared 1
ac_log "AC 2: conditions gone on the next tick → {acted:1, cleared:1}"
rc=0
out="$(judge "$TAPE1" "$STATE1" 1100 "$FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "a tick while the diagnosed condition still fires must return 0 (got $rc): $out"
ac_assert_eq "$(jq -sr '[.[] | select(.type == "outcome")] | length' "$TAPE1/tape.jsonl")" "0" \
  "a diagnose entry must stay open while one of its conditions is still firing"
ac_assert_eq "$(jq -r --arg k "diagnose-${PROPOSAL1}" 'has($k)' "$STATE1")" "true" \
  "the diagnose state entry must remain while its condition is firing"

rc=0
out="$(judge "$TAPE1" "$STATE1" 1200 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "clearing a diagnosed condition must not fail the tick (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.bits == {"acted": 1, "cleared": 1} and .type == "outcome" and .proposal_id == "$PROPOSAL1"
JQ
)" "$(jq -c 'select(.type == "outcome")' "$TAPE1/tape.jsonl")" \
  "none of the diagnosed conditions firing inside the window must set acted 1 and cleared 1"
ac_assert_eq "$(jq -r --arg k "diagnose-${PROPOSAL1}" 'has($k)' "$STATE1")" "false" \
  "the judged diagnose entry must drop out of the state file"
ac_log "AC 2 OK"

# ── 3. gate off: a tick without escalation writes no diagnose proposal ────
ac_log "AC 3: a tick without escalation writes no diagnose proposal"
if gate_keeps_session "$FIRED" off; then
  ac_fail "the default gate must not keep the session"
fi
TAPE3="$WORK/tape-off"
STATE3="$WORK/state-off.json"
rc=0
out="$(judge "$TAPE3" "$STATE3" 3000 "$FIRED")" || rc=$?
ac_assert_eq "$rc" "0" "a non-escalating tick must return 0 (got $rc): $out"
ac_assert_eq "$(diagnose_count "$TAPE3/tape.jsonl")" "0" \
  "a tick without escalation must write no diagnose proposal"
ac_log "AC 3 OK"

ac_pass
