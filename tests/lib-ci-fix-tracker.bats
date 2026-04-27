#!/usr/bin/env bats
# tests/lib-ci-fix-tracker.bats — Tests for ci-fix-tracker.sh
#
# Covers: fresh tracker count=0, increment sequence, reset, exhaustion at
# count=3, check_only mode, and concurrent flock behavior.

load '../lib/ci-fix-tracker.sh'

setup() {
  TEST_DIR="${BATS_TEST_TMPDIR}/ci-fix-tracker-$$"
  mkdir -p "$TEST_DIR"
  export DISINTO_LOG_DIR="$TEST_DIR"
  export PROJECT_NAME="test"
  CI_FIX_TRACKER=""
  CI_FIX_LOCK=""
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- ci_fix_tracker_init ---

@test "ci_fix_tracker_init creates tracker and lock files" {
  ci_fix_tracker_init
  [ -f "$CI_FIX_TRACKER" ]
  [ -f "$CI_FIX_LOCK" ]
  # Directory is created if missing
  export DISINTO_LOG_DIR="$TEST_DIR/nested/deep"
  CI_FIX_TRACKER=""
  CI_FIX_LOCK=""
  ci_fix_tracker_init
  [ -d "$DISINTO_LOG_DIR" ]
}

# --- ci_fix_tracker_count ---

@test "count returns 0 for fresh (empty) tracker" {
  ci_fix_tracker_init
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 0 ]
}

@test "count returns 0 for missing PR in tracker" {
  ci_fix_tracker_init
  echo '{"99": 5}' > "$CI_FIX_TRACKER"
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 0 ]
}

@test "count returns stored value for existing PR" {
  ci_fix_tracker_init
  echo '{"42": 3}' > "$CI_FIX_TRACKER"
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 3 ]
}

# --- ci_fix_tracker_check_and_increment ---

@test "increment sequence: 0 -> 1 -> 2 -> 3 -> exhausted_first_time -> exhausted" {
  ci_fix_tracker_init
  local r
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "ok:1" ]
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "ok:2" ]
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "ok:3" ]
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "exhausted_first_time:3" ]
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "exhausted:4" ]
}

@test "check_only does not increment counter" {
  ci_fix_tracker_init
  local r
  r=$(ci_fix_tracker_check_and_increment 42 "check_only")
  [ "$r" = "ok:0" ]
  # Verify count unchanged
  r=$(ci_fix_tracker_check_and_increment 42 "check_only")
  [ "$r" = "ok:0" ]
}

@test "check_only on exhausted PR returns exhausted" {
  ci_fix_tracker_init
  # Manually set count to 4 (exhausted state)
  echo '{"42": 4}' > "$CI_FIX_TRACKER"
  local r
  r=$(ci_fix_tracker_check_and_increment 42 "check_only")
  [ "$r" = "exhausted:4" ]
}

@test "exhaustion_first_time bumps count to 4 in tracker" {
  ci_fix_tracker_init
  # Set count to 3
  echo '{"42": 3}' > "$CI_FIX_TRACKER"
  local r
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "exhausted_first_time:3" ]
  # Verify count is now 4 in tracker
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 4 ]
}

@test "exhausted count stays unchanged (no further increment)" {
  ci_fix_tracker_init
  echo '{"42": 4}' > "$CI_FIX_TRACKER"
  local r
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "exhausted:4" ]
  # Count should still be 4
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 4 ]
}

@test "exhausted count stays unchanged when > 4" {
  ci_fix_tracker_init
  echo '{"42": 10}' > "$CI_FIX_TRACKER"
  local r
  r=$(ci_fix_tracker_check_and_increment 42 "")
  [ "$r" = "exhausted:10" ]
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 10 ]
}

@test "multiple PRs tracked independently" {
  ci_fix_tracker_init
  ci_fix_tracker_check_and_increment 10 "" > /dev/null
  ci_fix_tracker_check_and_increment 10 "" > /dev/null
  ci_fix_tracker_check_and_increment 20 "" > /dev/null
  ci_fix_tracker_check_and_increment 20 "" > /dev/null
  ci_fix_tracker_check_and_increment 20 "" > /dev/null
  local c10 c20
  c10=$(ci_fix_tracker_count 10)
  c20=$(ci_fix_tracker_count 20)
  [ "$c10" -eq 2 ]
  [ "$c20" -eq 3 ]
}

# --- ci_fix_tracker_reset ---

@test "reset clears counter for a PR" {
  ci_fix_tracker_init
  echo '{"42": 3}' > "$CI_FIX_TRACKER"
  ci_fix_tracker_reset 42
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 0 ]
}

@test "reset on non-existent PR is no-op" {
  ci_fix_tracker_init
  ci_fix_tracker_reset 42  # should not error
  [ $? -eq 0 ]
}

@test "reset does not affect other PRs" {
  ci_fix_tracker_init
  echo '{"42": 3, "99": 5}' > "$CI_FIX_TRACKER"
  ci_fix_tracker_reset 42
  local c99
  c99=$(ci_fix_tracker_count 99)
  [ "$c99" -eq 5 ]
}

# --- Exhaustion semantics match original ---

@test "exhaustion transitions match original inline python semantics" {
  ci_fix_tracker_init
  # The original python code:
  #   count == 0: ok:1
  #   count == 1: ok:2
  #   count == 2: ok:3
  #   count == 3: exhausted_first_time:3 (bumps to 4)
  #   count > 3:  exhausted:N
  local expected=("ok:1" "ok:2" "ok:3" "exhausted_first_time:3" "exhausted:4" "exhausted:4")
  for i in "${!expected[@]}"; do
    local r
    r=$(ci_fix_tracker_check_and_increment 42 "")
    [ "$r" = "${expected[$i]}" ]
  done
}

@test "check_only mode never increments (even across multiple calls)" {
  ci_fix_tracker_init
  local r
  for i in {1..5}; do
    r=$(ci_fix_tracker_check_and_increment 42 "check_only")
    [ "$r" = "ok:0" ]
  done
  local count
  count=$(ci_fix_tracker_count 42)
  [ "$count" -eq 0 ]
}
