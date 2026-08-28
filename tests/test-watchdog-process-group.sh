#!/usr/bin/env bash
# test-watchdog-process-group.sh — Test that claude_run_with_watchdog kills orphan children
#
# Scenario 1 (idle-after-result watchdog):
#   A fake "claude" emits the final result marker, spawns a long-running
#   child (sleep 3600), and keeps running. The CLAUDE_IDLE_GRACE watchdog
#   must kill the whole process group, so the child dies with the parent.
#
# Scenario 2 (hard ceiling, #1070):
#   A fake "claude" NEVER emits a result marker and spawns a long-running
#   child (sleep 4500). Only the CLAUDE_TIMEOUT ceiling can stop it. Before
#   the fix, the ceiling line was an unguarded `timeout` in a `set -e`
#   subshell: exit 124 aborted the subshell before the process-group kill
#   ran, orphaning claude (and the child) to PID 1. Now: exit 124 is
#   captured, the whole group is killed, and the run is logged as
#   `timeout_exit=124` with the observed wall-clock.
#
# Both wrappers run claude_run_with_watchdog in a `bash -c` subshell that
# sources lib/agent-sdk.sh — which enables `set -euo pipefail`, exactly like
# the production call site (command substitution in agent_run). The wrapper
# defines log() because functions are not inherited across the bash -c
# boundary.
#
# Usage: ./tests/test-watchdog-process-group.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP="/tmp/test-watchdog-$$"
LOGFILE="${TEST_TMP}/log.txt"
PASS=true

# shellcheck disable=SC2317
cleanup_test() {
  rm -rf "$TEST_TMP"
}
trap cleanup_test EXIT INT TERM

mkdir -p "$TEST_TMP"
: > "$LOGFILE"

log() {
  printf '[TEST] %s\n' "$*" | tee -a "$LOGFILE"
}

fail() {
  printf '[TEST] FAIL: %s\n' "$*" | tee -a "$LOGFILE"
  PASS=false
}

pass() {
  printf '[TEST] PASS: %s\n' "$*" | tee -a "$LOGFILE"
}

# --- Scenario 1: idle-after-result watchdog kills the process group ---
# Fake claude: emits the result marker, spawns a child that would orphan if
# the group is not killed, then stays running.
cat > "${TEST_TMP}/fake-claude" << FAKE_CLAUDE_EOF
#!/usr/bin/env bash
# Marker must carry "subtype" — the watcher only matches the real result
# frame ("type":"result","subtype":...) so echoed text can't trigger it (#581).
echo '{"type":"result","subtype":"success","session_id":"test-session-123","is_error":false}'
sleep 3600 &
echo \$! > ${TEST_TMP}/child1.pid
while true; do
  sleep 3600 &
  wait \$! 2>/dev/null || true
done
FAKE_CLAUDE_EOF
chmod +x "${TEST_TMP}/fake-claude"

# Wrapper env, exported so the bash -c subshells below inherit them
# (fork-only assignments would trip shellcheck SC2097/SC2098 in CI).
export WD_SRC="${SCRIPT_DIR}" WD_TEST_TMP="${TEST_TMP}" WD_LOG="${LOGFILE}"

log "Scenario 1: idle-after-result group kill (timeout=10 grace=2)..."
export CLAUDE_TIMEOUT=10 CLAUDE_IDLE_GRACE=2
timeout 60 bash -c '
  export LOGFILE="$WD_LOG"
  log() { printf "[S1] %s\n" "$*" >> "$WD_LOG"; }
  source "$WD_SRC/lib/agent-sdk.sh"
  rc=0
  claude_run_with_watchdog "$WD_TEST_TMP/fake-claude" > "$WD_TEST_TMP/out1.txt" 2>&1 || rc=$?
  echo "$rc" > "$WD_TEST_TMP/rc1"
  exit 0
' || true

log "Scenario 1: waiting for reaping..."
sleep 5

RC1=$(cat "${TEST_TMP}/rc1" 2>/dev/null || echo "missing")
if [ "$RC1" = "0" ]; then
  pass "scenario 1: watchdog returned 0 (group killed after idle result)"
else
  fail "scenario 1: expected rc=0, got rc=${RC1}"
fi

CHILD1=$(cat "${TEST_TMP}/child1.pid" 2>/dev/null || echo "")
if [ -n "$CHILD1" ] && [ ! -d "/proc/${CHILD1}" ]; then
  pass "scenario 1: child ${CHILD1} (sleep 3600) is dead"
else
  fail "scenario 1: child ${CHILD1:-?} (sleep 3600) still alive — orphan leaked"
fi

if pgrep -f "${TEST_TMP}/fake-claude" >/dev/null 2>&1; then
  fail "scenario 1: fake-claude process still running"
else
  pass "scenario 1: fake-claude process terminated"
fi

if grep -q "timeout_exit=0" "$LOGFILE"; then
  pass "scenario 1: watchdog logged timeout_exit=0 with wall-clock"
else
  fail "scenario 1: no 'timeout_exit=0' watchdog log line found"
fi

# --- Scenario 2: hard ceiling kills a session that never emits a marker ---
# Fake claude: NO result marker (the idle watcher never fires), spawns a
# child that outlives CLAUDE_TIMEOUT, stays running.
cat > "${TEST_TMP}/fake-claude-2" << FAKE2_EOF
#!/usr/bin/env bash
sleep 4500 &
echo \$! > ${TEST_TMP}/child2.pid
while true; do
  sleep 4500 &
  wait \$! 2>/dev/null || true
done
FAKE2_EOF
chmod +x "${TEST_TMP}/fake-claude-2"

log "Scenario 2: CLAUDE_TIMEOUT ceiling on a marker-less run (timeout=5)..."
export CLAUDE_TIMEOUT=5 CLAUDE_IDLE_GRACE=2
export CLAUDE_PGID_FILE="${TEST_TMP}/pgid2"
timeout 60 bash -c '
  export LOGFILE="$WD_LOG"
  log() { printf "[S2] %s\n" "$*" >> "$WD_LOG"; }
  source "$WD_SRC/lib/agent-sdk.sh"
  rc=0
  claude_run_with_watchdog "$WD_TEST_TMP/fake-claude-2" > "$WD_TEST_TMP/out2.txt" 2>&1 || rc=$?
  echo "$rc" > "$WD_TEST_TMP/rc2"
  exit 0
' || true

log "Scenario 2: waiting for reaping..."
sleep 5

RC2=$(cat "${TEST_TMP}/rc2" 2>/dev/null || echo "missing")
if [ "$RC2" = "124" ]; then
  pass "scenario 2: ceiling fired, rc=124 captured (set -e no longer aborts the caller)"
else
  fail "scenario 2: expected rc=124, got rc=${RC2}"
fi

CHILD2=$(cat "${TEST_TMP}/child2.pid" 2>/dev/null || echo "")
if [ -n "$CHILD2" ] && [ ! -d "/proc/${CHILD2}" ]; then
  pass "scenario 2: child ${CHILD2} (sleep 4500) is dead"
else
  fail "scenario 2: child ${CHILD2:-?} (sleep 4500) still alive — orphan leaked past CLAUDE_TIMEOUT"
fi

if pgrep -f "${TEST_TMP}/fake-claude-2" >/dev/null 2>&1; then
  fail "scenario 2: fake-claude-2 process still running"
else
  pass "scenario 2: fake-claude-2 process terminated"
fi

if [ ! -f "${TEST_TMP}/pgid2" ]; then
  pass "scenario 2: CLAUDE_PGID_FILE removed once the group was dead"
else
  fail "scenario 2: CLAUDE_PGID_FILE still present ($(cat "${TEST_TMP}/pgid2" 2>/dev/null))"
fi

if grep -q "timeout_exit=124" "$LOGFILE"; then
  pass "scenario 2: watchdog logged timeout_exit=124 with wall-clock"
else
  fail "scenario 2: no 'timeout_exit=124' watchdog log line found"
fi

# Summary
echo ""
if [ "$PASS" = true ]; then
  log "All tests passed!"
  exit 0
else
  log "Some tests failed. See log at $LOGFILE"
  exit 1
fi
