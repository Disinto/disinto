#!/usr/bin/env bash
# test-watchdog-process-group.sh — Test that claude_run_with_watchdog kills orphan children
#
# This test verifies that when claude_run_with_watchdog terminates the Claude process,
# all child processes (including those spawned by Claude's Bash tool) are also killed.
#
# Reproducer scenario:
#   1. Create a fake "claude" stub that:
#      a. Spawns a long-running child process (sleep 3600)
#      b. Writes a result marker to stdout to trigger idle detection
#      c. Stays running
#   2. Run claude_run_with_watchdog with the stub
#   3. Before the fix: sleep child survives (orphaned to PID 1)
#   4. After the fix: sleep child dies (killed as part of process group with -PID)
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

# Export required environment variables
export CLAUDE_TIMEOUT=10       # Short timeout for testing
export CLAUDE_IDLE_GRACE=2     # Short grace period for testing
export LOGFILE="${LOGFILE}"    # Required by agent-sdk.sh

# Create a fake claude stub that:
# 1. Spawns a long-running child process (sleep 3600) that will become an orphan if parent is killed
# 2. Writes a result marker to stdout (to trigger the watchdog's idle-after-result path)
# 3. Stays running so the watchdog can kill it
cat > "${TEST_TMP}/fake-claude" << 'FAKE_CLAUDE_EOF'
#!/usr/bin/env bash
# Fake claude that spawns a child and stays running
# Simulates Claude's behavior when it spawns a Bash tool command

# Write result marker to stdout (triggers watchdog idle detection)
echo '{"type":"result","session_id":"test-session-123","verdict":"APPROVE"}'

# Spawn a child that simulates Claude's Bash tool hanging
# This is the process that should be killed when the parent is terminated
sleep 3600 &
CHILD_PID=$!

# Log the child PID for debugging
echo "FAKE_CLAUDE_CHILD_PID=$CHILD_PID" >&2

# Stay running - sleep in a loop so the watchdog can kill us
while true; do
  sleep 3600 &
  wait $! 2>/dev/null || true
done
FAKE_CLAUDE_EOF
chmod +x "${TEST_TMP}/fake-claude"

log "Testing claude_run_with_watchdog process group cleanup..."

# Source the library and run claude_run_with_watchdog
cd "$SCRIPT_DIR"
source lib/agent-sdk.sh

log "Starting claude_run_with_watchdog with fake claude..."

# Run the function directly (not as a script)
# We need to capture output and redirect stderr
OUTPUT_FILE="${TEST_TMP}/output.txt"
timeout 35 bash -c "
  source '${SCRIPT_DIR}/lib/agent-sdk.sh'
  CLAUDE_TIMEOUT=10 CLAUDE_IDLE_GRACE=2 LOGFILE='${LOGFILE}' claude_run_with_watchdog '${TEST_TMP}/fake-claude' > '${OUTPUT_FILE}' 2>&1
  exit \$?
" || true

# Give the watchdog a moment to clean up
log "Waiting for cleanup..."
sleep 5

# More precise check: look for sleep 3600 processes
# These would be the orphans from our fake claude
ORPHAN_COUNT=$(pgrep -a sleep 2>/dev/null | grep -c "sleep 3600" 2>/dev/null || echo "0")

if [ "$ORPHAN_COUNT" -gt 0 ]; then
  log "Found $ORPHAN_COUNT orphan sleep 3600 processes:"
  pgrep -a sleep | grep "sleep 3600"
  fail "Orphan children found - process group cleanup did not work"
else
  pass "No orphan children found - process group cleanup worked"
fi

# Also verify that the fake claude itself is not running
FAKE_CLAUDE_COUNT=$(pgrep -c -f "fake-claude" 2>/dev/null || echo "0")
if [ "$FAKE_CLAUDE_COUNT" -gt 0 ]; then
  log "Found $FAKE_CLAUDE_COUNT fake-claude processes still running"
  fail "Fake claude process(es) still running"
else
  pass "Fake claude process terminated"
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
