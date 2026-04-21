# tests/test-lint-ci.bats — Tests for `disinto validate lint-ci`
#
# Verifies the CI timeout validator:
#   1. Step-level timeout errors fire when missing
#   2. Workflow-level timeout satisfies all steps
#   3. curl without --max-time triggers a warning
#   4. curl with --max-time passes cleanly

load bats

DISINTO="${FACTORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/bin/disinto"
FIXTURES="$(cd "$(dirname "$0")/fixtures/lint-ci" && pwd)"

# ── Step-level timeout errors ────────────────────────────────────────────────

@test "missing step timeout triggers error" {
  local output
  output=$(bash "$DISINTO" validate lint-ci "$FIXTURES/missing-timeout" 2>&1)
  local rc=$?
  echo "$output"
  [ "$rc" -eq 1 ]
  echo "$output" | grep -q "error:.*no-timeout-step.*step has no timeout"
}

@test "workflow-level timeout satisfies all steps" {
  local output
  output=$(bash "$DISINTO" validate lint-ci "$FIXTURES/workflow-timeout" 2>&1)
  local rc=$?
  echo "$output"
  [ "$rc" -eq 0 ]
  echo "$output" | grep -q "lint-ci: 0 error(s), 0 warning(s)"
}

# ── Command-level timeout warnings ───────────────────────────────────────────

@test "curl without --max-time triggers warning" {
  local output
  output=$(bash "$DISINTO" validate lint-ci "$FIXTURES/bad-curl" 2>&1)
  local rc=$?
  echo "$output"
  [ "$rc" -eq 0 ]
  echo "$output" | grep -q "warning:.*curl without --max-time"
}

@test "curl with --max-time passes cleanly" {
  local output
  output=$(bash "$DISINTO" validate lint-ci "$FIXTURES/good-curl" 2>&1)
  local rc=$?
  echo "$output"
  [ "$rc" -eq 0 ]
  echo "$output" | grep -q "lint-ci: 0 error(s), 0 warning(s)"
}
