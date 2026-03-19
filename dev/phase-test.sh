#!/usr/bin/env bash
# phase-test.sh — Integration test for the phase-signaling protocol
#
# Simulates a Claude session writing phases and an orchestrator reading them.
# Tests all phase values and verifies the read/write contract.
#
# Usage: bash dev/phase-test.sh

set -euo pipefail

PROJECT="testproject"
ISSUE="999"
PHASE_FILE="/tmp/dev-session-${PROJECT}-${ISSUE}.phase"

PASS=0
FAIL=0

ok() {
  printf '[PASS] %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL=$((FAIL + 1))
}

# Cleanup
rm -f "$PHASE_FILE"

# ── Test 1: phase file path convention ────────────────────────────────────────
expected_path="/tmp/dev-session-${PROJECT}-${ISSUE}.phase"
if [ "$PHASE_FILE" = "$expected_path" ]; then
  ok "phase file path follows /tmp/dev-session-{project}-{issue}.phase convention"
else
  fail "phase file path mismatch: got $PHASE_FILE, expected $expected_path"
fi

# ── Test 2: write and read each phase sentinel ─────────────────────────────────
check_phase() {
  local sentinel="$1"
  echo "$sentinel" > "$PHASE_FILE"
  local got
  got=$(tr -d '[:space:]' < "$PHASE_FILE")
  if [ "$got" = "$sentinel" ]; then
    ok "write/read: $sentinel"
  else
    fail "write/read: expected '$sentinel', got '$got'"
  fi
}

check_phase "PHASE:awaiting_ci"
check_phase "PHASE:awaiting_review"
check_phase "PHASE:needs_human"
check_phase "PHASE:done"
check_phase "PHASE:failed"

# ── Test 3: write overwrites (not appends) ─────────────────────────────────────
echo "PHASE:awaiting_ci" > "$PHASE_FILE"
echo "PHASE:awaiting_review" > "$PHASE_FILE"
line_count=$(wc -l < "$PHASE_FILE")
file_content=$(< "$PHASE_FILE")
if [ "$line_count" -eq 1 ]; then
  ok "phase file overwrite (single line after two writes)"
else
  fail "phase file should have 1 line, got $line_count"
fi
if [ "$file_content" = "PHASE:awaiting_review" ]; then
  ok "phase file overwrite (content is second write, not first)"
else
  fail "phase file content should be 'PHASE:awaiting_review', got '$file_content'"
fi

# ── Test 4: failed phase with reason ──────────────────────────────────────────
printf 'PHASE:failed\nReason: %s\n' "shellcheck failed on ci.sh" > "$PHASE_FILE"
first_line=$(head -1 "$PHASE_FILE")
second_line=$(sed -n '2p' "$PHASE_FILE")
if [ "$first_line" = "PHASE:failed" ] && echo "$second_line" | grep -q "^Reason:"; then
  ok "PHASE:failed with reason line"
else
  fail "PHASE:failed format: first='$first_line' second='$second_line'"
fi

# ── Test 5: orchestrator read function ────────────────────────────────────────
read_phase() {
  local pfile="$1"
  # Allow cat to fail (missing file) — pipeline exits 0 via || true
  { cat "$pfile" 2>/dev/null || true; } | head -1 | tr -d '[:space:]'
}

echo "PHASE:awaiting_ci" > "$PHASE_FILE"
phase=$(read_phase "$PHASE_FILE")
if [ "$phase" = "PHASE:awaiting_ci" ]; then
  ok "orchestrator read_phase() extracts first line"
else
  fail "orchestrator read_phase() got: '$phase'"
fi

# ── Test 6: missing file returns empty ────────────────────────────────────────
rm -f "$PHASE_FILE"
phase=$(read_phase "$PHASE_FILE")
if [ -z "$phase" ]; then
  ok "missing phase file returns empty string"
else
  fail "missing phase file should return empty, got: '$phase'"
fi

# ── Test 7: all valid phase values are recognized ─────────────────────────────
is_valid_phase() {
  local p="$1"
  case "$p" in
    PHASE:awaiting_ci|PHASE:awaiting_review|PHASE:needs_human|PHASE:done|PHASE:failed)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

for p in "PHASE:awaiting_ci" "PHASE:awaiting_review" "PHASE:needs_human" \
         "PHASE:done" "PHASE:failed"; do
  if is_valid_phase "$p"; then
    ok "is_valid_phase: $p"
  else
    fail "is_valid_phase rejected valid phase: $p"
  fi
done

if ! is_valid_phase "PHASE:unknown"; then
  ok "is_valid_phase rejects unknown phase"
else
  fail "is_valid_phase should reject PHASE:unknown"
fi

# ── Test 8: needs_human mtime guard — no duplicate notify on second poll ─────
# Simulates the LAST_PHASE_MTIME guard from dev-agent.sh: after the orchestrator
# handles PHASE:needs_human once, subsequent poll cycles must not re-trigger
# notify() if the phase file was not rewritten.
NOTIFY_COUNT=0
mock_notify() { NOTIFY_COUNT=$((NOTIFY_COUNT + 1)); }

echo "PHASE:needs_human" > "$PHASE_FILE"
LAST_PHASE_MTIME=0

# --- First poll cycle: phase file is newer than LAST_PHASE_MTIME ---
PHASE_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
CURRENT_PHASE=$(tr -d '[:space:]' < "$PHASE_FILE")

if [ -n "$CURRENT_PHASE" ] && [ "$PHASE_MTIME" -gt "$LAST_PHASE_MTIME" ]; then
  # Orchestrator would handle the phase and call notify()
  mock_notify
  LAST_PHASE_MTIME="$PHASE_MTIME"
fi

# --- Second poll cycle: file not touched, mtime unchanged ---
sleep 1  # ensure wall-clock advances past the original mtime
PHASE_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
CURRENT_PHASE=$(tr -d '[:space:]' < "$PHASE_FILE")

if [ -n "$CURRENT_PHASE" ] && [ "$PHASE_MTIME" -gt "$LAST_PHASE_MTIME" ]; then
  # This branch must NOT execute — mtime guard should block it
  mock_notify
fi

if [ "$NOTIFY_COUNT" -eq 1 ]; then
  ok "needs_human mtime guard: notify called once, blocked on second poll"
else
  fail "needs_human mtime guard: expected 1 notify call, got $NOTIFY_COUNT"
fi

# ── Test 9: PostToolUse hook writes marker on phase file reference ────────
HOOK_SCRIPT="$(dirname "$0")/../lib/hooks/on-phase-change.sh"
MARKER_FILE="/tmp/phase-changed-test-session.marker"
rm -f "$MARKER_FILE"

if [ -x "$HOOK_SCRIPT" ]; then
  # Simulate hook input that references the phase file
  echo "{\"tool_input\":{\"command\":\"echo PHASE:awaiting_ci > ${PHASE_FILE}\"}}" \
    | bash "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook writes marker when phase file referenced"
  else
    fail "PostToolUse hook did not write marker"
  fi
  rm -f "$MARKER_FILE"

  # Simulate hook input that does NOT reference the phase file
  echo "{\"tool_input\":{\"command\":\"echo hello > /tmp/other-file\"}}" \
    | bash "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ ! -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook skips marker for unrelated operations"
  else
    fail "PostToolUse hook wrote marker for unrelated operation (false positive)"
  fi
  rm -f "$MARKER_FILE"
else
  fail "PostToolUse hook script not found or not executable: $HOOK_SCRIPT"
fi

# ── Test 10: phase-changed marker resets mtime guard ─────────────────────
# Simulates monitor_phase_loop behavior: when marker exists, last_mtime
# is reset to 0 so the phase is processed even if mtime hasn't changed.
echo "PHASE:awaiting_ci" > "$PHASE_FILE"
LAST_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
PHASE_MTIME="$LAST_MTIME"

# Without marker, mtime guard blocks processing (same mtime)
if [ "$PHASE_MTIME" -le "$LAST_MTIME" ]; then
  ok "mtime guard blocks when no marker present (baseline)"
else
  fail "mtime guard should block when phase_mtime <= last_mtime"
fi

# Now simulate marker present — reset last_mtime to 0
MARKER_FILE="/tmp/phase-changed-test-session.marker"
date +%s > "$MARKER_FILE"
if [ -f "$MARKER_FILE" ]; then
  rm -f "$MARKER_FILE"
  LAST_MTIME=0
fi

if [ "$PHASE_MTIME" -gt "$LAST_MTIME" ]; then
  ok "phase-changed marker resets mtime guard (phase now processable)"
else
  fail "phase-changed marker did not reset mtime guard"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$PHASE_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
