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
