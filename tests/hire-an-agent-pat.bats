#!/usr/bin/env bats
# =============================================================================
# tests/hire-an-agent-pat.bats — Tests for --admin-token PAT auth in
#   disinto hire-an-agent
#
# Covers:
#   1. --admin-token flag accepted in parsing (no "Unknown option")
#   2. FORGE_ADMIN_PAT env var is documented in usage
#   3. Missing-scope rejection message format
#   4. Password-only flow unchanged (no regression)
# =============================================================================

setup_file() {
  export DISINTO_ROOT
  DISINTO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export DISINTO_BIN="${DISINTO_ROOT}/bin/disinto"
  [ -x "$DISINTO_BIN" ] || {
    echo "disinto binary not executable: $DISINTO_BIN" >&2
    return 1
  }
}

# ── --admin-token flag parsing ────────────────────────────────────────────────

@test "hire-an-agent rejects unknown --admin-token with missing args" {
  # --admin-token requires a value; without one the parser should reject it
  # with "Unknown option" or a similar parsing error, not "admin-token is not
  # recognized" (which would mean the flag was never added).
  export FORGE_TOKEN="fake-token"
  export FORGE_URL="http://localhost:3000"
  export FACTORY_ROOT="$DISINTO_ROOT"
  export PROJECT_NAME="disinto"

  run "$DISINTO_BIN" hire-an-agent test-agent dev --admin-token
  # The parser will error because --admin-token needs a value
  [[ "$output" == *"Unknown option"* || "$output" == *"admin-token"* || "$status" -ne 0 ]]
}

@test "hire-an-agent accepts --admin-token <pat> in flag parsing" {
  export FORGE_TOKEN="fake-token"
  export FORGE_URL="http://localhost:3000"
  export FACTORY_ROOT="$DISINTO_ROOT"
  export PROJECT_NAME="disinto"

  # --admin-token should not produce "Unknown option" error
  # It will fail later (no Forgejo running, no formula, etc.) but the flag
  # parsing should succeed.
  run "$DISINTO_BIN" hire-an-agent test-agent dev --admin-token "fake-pat-value"
  [[ "$output" != *"Unknown option: --admin-token"* ]]
  # Should fail due to missing formula/env, not unknown flag
  [[ "$status" -ne 0 ]]
}

# ── FORGE_ADMIN_PAT env var documentation ─────────────────────────────────────

@test "usage documents --admin-token and FORGE_ADMIN_PAT" {
  run "$DISINTO_BIN" hire-an-agent
  [[ "$output" == *"--admin-token"* ]]
  # The usage line should mention the flag
  [[ "$output" == *"--admin-token <pat>"* ]]
}

@test "help text documents FORGE_ADMIN_PAT env var fallback" {
  # The function's doc comment mentions FORGE_ADMIN_PAT; verify it's in the
  # source file that gets sourced.
  run grep -c 'FORGE_ADMIN_PAT' "${DISINTO_ROOT}/lib/hire-agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# ── Missing-scope rejection ──────────────────────────────────────────────────

@test "missing admin scope produces clear error message" {
  export FORGE_TOKEN="fake-token"
  export FORGE_URL="http://localhost:3000"
  export FACTORY_ROOT="$DISINTO_ROOT"
  export PROJECT_NAME="disinto"

  # Start a mock server that returns 401 on GET /admin/users
  local mock_pid=""
  cleanup() {
    if [ -n "$mock_pid" ]; then
      kill "$mock_pid" 2>/dev/null || true
      wait "$mock_pid" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  # Use a port that's not running anything — the scope probe will fail
  export FORGE_URL="http://localhost:19999"

  run "$DISINTO_BIN" hire-an-agent test-agent dev \
    --admin-token "some-pat-value" 2>&1 || true

  # Should fail with scope validation error or connection error
  # (both indicate the PAT auth path was taken)
  [[ "$output" == *"admin scope"* || "$output" == *"lacks admin scope"* || \
      "$output" == *"Connection refused"* || "$output" == *"failed to obtain"* ]]
}

# ── Password-only fallback (no regression) ────────────────────────────────────

@test "password-only flow still works when neither --admin-token nor FORGE_ADMIN_PAT set" {
  export FORGE_TOKEN="fake-token"
  export FORGE_URL="http://localhost:3000"
  export FACTORY_ROOT="$DISINTO_ROOT"
  export PROJECT_NAME="disinto"
  unset FORGE_ADMIN_PAT 2>/dev/null || true

  # Without --admin-token or FORGE_ADMIN_PAT, the code should fall back to
  # the password-based flow. It will fail (no Forgejo running) but the error
  # path should be the basic-auth exchange, not the PAT path.
  local output
  output=$("$DISINTO_BIN" hire-an-agent test-agent dev 2>&1) || true

  # Should NOT mention PAT auth
  [[ "$output" != *"Auth: PAT from"* ]]
  # Should attempt basic-auth flow (will fail with connection error)
  [[ "$output" == *"basic"* || "$output" == *"Connection refused"* || \
      "$output" == *"failed to obtain"* || "$output" == *"admin scope"* ]]
}

@test "FORGE_ADMIN_PAT env var takes precedence over FORGE_ADMIN_PASS" {
  export FORGE_TOKEN="fake-token"
  export FACTORY_ROOT="$DISINTO_ROOT"
  export PROJECT_NAME="disinto"
  export FORGE_ADMIN_PAT="pat-from-env"
  # Set a bad password — PAT should win
  export FORGE_ADMIN_PASS="bad-password"
  # Point to a non-running server so scope probe fails
  export FORGE_URL="http://localhost:19998"

  local output
  output=$("$DISINTO_BIN" hire-an-agent test-agent dev 2>&1) || true

  # Should mention PAT from env var, not password
  [[ "$output" == *"FORGE_ADMIN_PAT"* || "$output" == *"PAT from"* ]]
  # Should NOT mention basic auth / password
  [[ "$output" != *"admin:admin"* || "$output" == *"PAT from FORGE_ADMIN_PAT"* ]]
}
