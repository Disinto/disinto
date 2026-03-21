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

# ── Test 9: PostToolUse hook detects writes, ignores reads ────────────────
HOOK_SCRIPT="$(dirname "$0")/../lib/hooks/on-phase-change.sh"
MARKER_FILE="/tmp/phase-changed-test-session.marker"
rm -f "$MARKER_FILE"

if [ -x "$HOOK_SCRIPT" ]; then
  # 9a: Bash redirect to phase file → marker written
  printf '{"tool_name":"Bash","tool_input":{"command":"echo PHASE:awaiting_ci > %s"}}' \
    "$PHASE_FILE" | "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook writes marker on Bash redirect to phase file"
  else
    fail "PostToolUse hook did not write marker on Bash redirect"
  fi
  rm -f "$MARKER_FILE"

  # 9b: Write tool targeting phase file → marker written
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"PHASE:done"}}' \
    "$PHASE_FILE" | "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook writes marker on Write tool to phase file"
  else
    fail "PostToolUse hook did not write marker on Write tool"
  fi
  rm -f "$MARKER_FILE"

  # 9c: Bash read of phase file (cat) → NO marker (not a write)
  printf '{"tool_name":"Bash","tool_input":{"command":"cat %s"}}' \
    "$PHASE_FILE" | "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ ! -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook ignores Bash read of phase file (no false positive)"
  else
    fail "PostToolUse hook wrote marker for Bash read (false positive)"
  fi
  rm -f "$MARKER_FILE"

  # 9d: Unrelated Bash command → NO marker
  printf '{"tool_name":"Bash","tool_input":{"command":"echo hello > /tmp/other-file"}}' \
    | "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ ! -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook skips marker for unrelated operations"
  else
    fail "PostToolUse hook wrote marker for unrelated operation (false positive)"
  fi
  rm -f "$MARKER_FILE"

  # 9e: Write tool targeting different file → NO marker
  printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/other-file","content":"hello"}}' \
    | "$HOOK_SCRIPT" "$PHASE_FILE" "$MARKER_FILE"
  if [ ! -f "$MARKER_FILE" ]; then
    ok "PostToolUse hook skips marker for Write to different file"
  else
    fail "PostToolUse hook wrote marker for Write to different file (false positive)"
  fi
  rm -f "$MARKER_FILE"
else
  fail "PostToolUse hook script not found or not executable: $HOOK_SCRIPT"
fi

# ── Test 10: StopFailure hook writes phase file and marker on API error ───
STOP_FAILURE_HOOK="$(dirname "$0")/../lib/hooks/on-stop-failure.sh"
SF_MARKER="/tmp/phase-changed-test-sf.marker"
rm -f "$SF_MARKER" "$PHASE_FILE"

if [ -x "$STOP_FAILURE_HOOK" ]; then
  # 10a: rate_limit stop reason → PHASE:failed with api_error reason
  printf '{"stop_reason":"rate_limit"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" "$SF_MARKER"
  sf_first=$(head -1 "$PHASE_FILE" 2>/dev/null)
  sf_second=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null)
  if [ "$sf_first" = "PHASE:failed" ] && echo "$sf_second" | grep -q "api_error: rate_limit"; then
    ok "StopFailure hook writes PHASE:failed with api_error: rate_limit"
  else
    fail "StopFailure hook phase file: first='$sf_first' second='$sf_second'"
  fi
  if [ -f "$SF_MARKER" ]; then
    ok "StopFailure hook writes phase-changed marker"
  else
    fail "StopFailure hook did not write phase-changed marker"
  fi
  rm -f "$SF_MARKER" "$PHASE_FILE"

  # 10b: server_error stop reason
  printf '{"stop_reason":"server_error"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" "$SF_MARKER"
  sf_second=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null)
  if echo "$sf_second" | grep -q "api_error: server_error"; then
    ok "StopFailure hook writes api_error: server_error"
  else
    fail "StopFailure hook server_error: got '$sf_second'"
  fi
  rm -f "$SF_MARKER" "$PHASE_FILE"

  # 10c: authentication_failed stop reason
  printf '{"stop_reason":"authentication_failed"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" "$SF_MARKER"
  sf_second=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null)
  if echo "$sf_second" | grep -q "api_error: authentication_failed"; then
    ok "StopFailure hook writes api_error: authentication_failed"
  else
    fail "StopFailure hook authentication_failed: got '$sf_second'"
  fi
  rm -f "$SF_MARKER" "$PHASE_FILE"

  # 10e: missing phase_file arg → no-op (exit 0, no crash)
  printf '{"stop_reason":"rate_limit"}' | "$STOP_FAILURE_HOOK" "" "$SF_MARKER"
  if [ ! -f "$PHASE_FILE" ]; then
    ok "StopFailure hook no-ops when phase_file is empty"
  else
    fail "StopFailure hook should not write when phase_file is empty"
  fi
  rm -f "$SF_MARKER"

  # 10f: missing marker arg → phase file still written, no marker
  printf '{"stop_reason":"billing_error"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" ""
  sf_first=$(head -1 "$PHASE_FILE" 2>/dev/null)
  sf_marker_exists="no"
  [ -f "$SF_MARKER" ] && sf_marker_exists="yes"
  if [ "$sf_first" = "PHASE:failed" ] && [ "$sf_marker_exists" = "no" ]; then
    ok "StopFailure hook writes phase without marker when marker arg is empty"
  else
    fail "StopFailure hook: first='$sf_first' marker_exists=$sf_marker_exists"
  fi
  rm -f "$PHASE_FILE"

  # 10g: terminal phase guard — does not overwrite PHASE:done
  echo "PHASE:done" > "$PHASE_FILE"
  printf '{"stop_reason":"rate_limit"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" "$SF_MARKER"
  sf_first=$(head -1 "$PHASE_FILE" 2>/dev/null)
  if [ "$sf_first" = "PHASE:done" ] && [ ! -f "$SF_MARKER" ]; then
    ok "StopFailure hook does not overwrite terminal PHASE:done"
  else
    fail "StopFailure hook overwrote PHASE:done: first='$sf_first'"
  fi
  rm -f "$SF_MARKER" "$PHASE_FILE"

  # 10h: terminal phase guard — does not overwrite PHASE:merged
  echo "PHASE:merged" > "$PHASE_FILE"
  printf '{"stop_reason":"server_error"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" "$SF_MARKER"
  sf_first=$(head -1 "$PHASE_FILE" 2>/dev/null)
  if [ "$sf_first" = "PHASE:merged" ] && [ ! -f "$SF_MARKER" ]; then
    ok "StopFailure hook does not overwrite terminal PHASE:merged"
  else
    fail "StopFailure hook overwrote PHASE:merged: first='$sf_first'"
  fi
  rm -f "$SF_MARKER" "$PHASE_FILE"

  # 10i: terminal phase guard — does not overwrite PHASE:needs_human
  echo "PHASE:needs_human" > "$PHASE_FILE"
  printf '{"stop_reason":"rate_limit"}' \
    | "$STOP_FAILURE_HOOK" "$PHASE_FILE" "$SF_MARKER"
  sf_first=$(head -1 "$PHASE_FILE" 2>/dev/null)
  if [ "$sf_first" = "PHASE:needs_human" ] && [ ! -f "$SF_MARKER" ]; then
    ok "StopFailure hook does not overwrite terminal PHASE:needs_human"
  else
    fail "StopFailure hook overwrote PHASE:needs_human: first='$sf_first'"
  fi
  rm -f "$SF_MARKER" "$PHASE_FILE"
else
  fail "StopFailure hook script not found or not executable: $STOP_FAILURE_HOOK"
fi

# ── Test 11: phase-changed marker resets mtime guard ─────────────────────
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
MARKER_FILE="/tmp/phase-changed-test-mtime.marker"
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

# ── Test 12: crash handler treats PHASE:needs_human as terminal ───────────
# Simulates the monitor_phase_loop crash handler: when a session exits while
# the phase file holds PHASE:needs_human, it must be treated as terminal
# (fall through to the phase handler) rather than invoking callback with
# PHASE:crashed, which would lose the escalation intent.
CRASH_CALLBACK_PHASE=""
mock_crash_callback() { CRASH_CALLBACK_PHASE="$1"; }

echo "PHASE:needs_human" > "$PHASE_FILE"
current_phase=$(head -1 "$PHASE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
case "$current_phase" in
  PHASE:done|PHASE:failed|PHASE:merged|PHASE:needs_human)
    # terminal — fall through to phase handler (correct behavior)
    mock_crash_callback "$current_phase"
    ;;
  *)
    # would invoke callback with PHASE:crashed (incorrect for needs_human)
    mock_crash_callback "PHASE:crashed"
    ;;
esac

if [ "$CRASH_CALLBACK_PHASE" = "PHASE:needs_human" ]; then
  ok "crash handler preserves PHASE:needs_human (not replaced by PHASE:crashed)"
else
  fail "crash handler lost escalation intent: expected PHASE:needs_human, got $CRASH_CALLBACK_PHASE"
fi

# Also verify the other terminal phases still work in crash handler
for tp in "PHASE:done" "PHASE:failed" "PHASE:merged"; do
  echo "$tp" > "$PHASE_FILE"
  current_phase=$(head -1 "$PHASE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
  case "$current_phase" in
    PHASE:done|PHASE:failed|PHASE:merged|PHASE:needs_human)
      ok "crash handler treats $tp as terminal"
      ;;
    *)
      fail "crash handler does not treat $tp as terminal"
      ;;
  esac
done

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
