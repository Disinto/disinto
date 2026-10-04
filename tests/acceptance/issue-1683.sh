#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1683.sh
#
# Issue #1683: dsh, the local model, is the default agent harness.
#
# Before: agent_run fell back to _agent_run_claude when AGENT_HARNESS was
# unset, and formula_session_start labelled that run "claude" on the tape.
# An organ deployed without the variable silently called Claude.
#
# After: the dispatcher and the tape label both default to dsh. claude
# remains available only when AGENT_HARNESS=claude is set explicitly.
#
# Acceptance (no network; harness functions stubbed; temp TAPE_DIR):
#   1. AGENT_HARNESS unset, both harness functions stubbed: agent_run calls
#      _agent_run_dsh and not _agent_run_claude.
#   2. AGENT_HARNESS=claude: agent_run calls _agent_run_claude and not
#      _agent_run_dsh.
#   3. AGENT_HARNESS unset: the run formula_session_start writes has an
#      agent starting with dsh.
#   4. bats tests/lib-agent-harness-dsh.bats passes.
#   5. a claude hire emits AGENT_HARNESS=claude (omission is dsh).
#   6. this test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1683
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash bats jq

SDK="$REPO_ROOT/lib/agent-sdk.sh"
FORMULA="$REPO_ROOT/lib/formula-session.sh"
SUITE="$REPO_ROOT/tests/lib-agent-harness-dsh.bats"
ac_assert_file "$SDK" "lib/agent-sdk.sh must exist"
ac_assert_file "$FORMULA" "lib/formula-session.sh must exist"
ac_assert_file "$SUITE" "tests/lib-agent-harness-dsh.bats must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# dispatch_driver <unset|claude>
# Sources agent-sdk.sh, stubs both harness functions, then calls agent_run.
# Prints the name of the function that ran (dsh or claude).
dispatch_driver() {
  local mode="$1"
  local driver assign
  driver="$(mktemp "${TMP_DIR}/dispatch.XXXXXX.sh")"
  if [ "$mode" = "unset" ]; then
    assign="unset AGENT_HARNESS"
  else
    assign="export AGENT_HARNESS=$mode"
  fi
  cat > "$driver" <<EOF
set -euo pipefail
log() { :; }
export SID_FILE="$TMP_DIR/sid"
export LOGFILE="$TMP_DIR/agent.log"
export LOG_AGENT=acceptance
export DISINTO_LOG_DIR="$TMP_DIR/logs"
export DSH_HOME="$TMP_DIR/dsh-home"
mkdir -p "\$DISINTO_LOG_DIR" "\$DSH_HOME"
unset AGENT_HARNESS
source "$SDK"
_agent_run_dsh() { printf 'dsh\n'; return 0; }
_agent_run_claude() { printf 'claude\n'; return 0; }
$assign
agent_run "go"
EOF
  bash "$driver"
}

# ── 1. Unset dispatches dsh, never claude ────────────────────────────────────
ac_log "AC 1: AGENT_HARNESS unset calls _agent_run_dsh"
rc=0
out="$(dispatch_driver unset)" || rc=$?
ac_assert_eq "$rc" "0" "unset agent_run must return 0 (got $rc): $out"
ac_assert_eq "$out" "dsh" \
  "AGENT_HARNESS unset must call _agent_run_dsh, got '$out'"
ac_log "AC 1 OK: unset dispatched dsh"

# ── 2. Explicit claude still dispatches claude ───────────────────────────────
ac_log "AC 2: AGENT_HARNESS=claude calls _agent_run_claude"
rc=0
out="$(dispatch_driver claude)" || rc=$?
ac_assert_eq "$rc" "0" "claude agent_run must return 0 (got $rc): $out"
ac_assert_eq "$out" "claude" \
  "AGENT_HARNESS=claude must call _agent_run_claude, got '$out'"
ac_log "AC 2 OK: explicit claude dispatched claude"

# ── 3. Tape run agent starts with dsh when the variable is unset ─────────────
ac_log "AC 3: formula_session_start labels the run dsh"
TAPE_DIR="$TMP_DIR/tape"
PAYLOAD_DIR="$TMP_DIR/payloads"
mkdir -p "$TAPE_DIR" "$PAYLOAD_DIR"
tape_driver="$(mktemp "${TMP_DIR}/tape.XXXXXX.sh")"
cat > "$tape_driver" <<EOF
set -euo pipefail
log() { :; }
unset AGENT_HARNESS CLAUDE_MODEL
export LOG_AGENT=acceptance
export DISINTO_LOG_DIR="$TMP_DIR/logs"
export TAPE_DIR="$TAPE_DIR"
export PAYLOAD_DIR="$PAYLOAD_DIR"
export TAPE_PROPOSAL_ID=prop-1683
source "$FORMULA"
formula_session_start "acceptance-organ"
EOF
rc=0
out="$(bash "$tape_driver" 2>&1)" || rc=$?
ac_assert_eq "$rc" "0" "formula_session_start must return 0 (got $rc): $out"
ac_assert_file "$TAPE_DIR/tape.jsonl" "formula_session_start must append a tape run"
agent="$(jq -r 'select(.type == "run") | .agent' "$TAPE_DIR/tape.jsonl" | head -n 1)"
case "$agent" in
  dsh*) ;;
  *) ac_fail "tape run agent must start with dsh, got '$agent'" ;;
esac
ac_log "AC 3 OK: tape agent is '$agent'"

# ── 4. The harness suite still passes ────────────────────────────────────────
ac_log "AC 4: bats tests/lib-agent-harness-dsh.bats"
bats_rc=0
bats_out="$(bats "$SUITE" 2>&1)" || bats_rc=$?
ac_assert_eq "$bats_rc" "0" \
  "bats tests/lib-agent-harness-dsh.bats must pass (rc=$bats_rc): $bats_out"
ac_log "AC 4 OK: harness suite passed"

# ── 5. A claude hire sets AGENT_HARNESS explicitly (omission is dsh) ─────────
ac_log "AC 5: claude hire emits AGENT_HARNESS=claude"
grep -qF 'AGENT_HARNESS      = "claude"' "$REPO_ROOT/lib/hire-agent.sh" \
  || ac_fail "lib/hire-agent.sh claude jobspec must emit AGENT_HARNESS=claude"
grep -qF 'AGENT_HARNESS: \"claude\"' "$REPO_ROOT/lib/generators.sh" \
  || ac_fail "lib/generators.sh claude compose block must emit AGENT_HARNESS=claude"
ac_log "AC 5 OK: claude hire sets AGENT_HARNESS explicitly"

ac_pass
