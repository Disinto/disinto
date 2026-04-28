#!/usr/bin/env bats
# =============================================================================
# tests/lib-agent-sdk-redact.bats — Unit tests for redact_log_secrets (#910)
#
# Covers the stream filter that masks token-shaped env-var assignments
# before they reach disk in lib/agent-sdk.sh's claude_run_with_watchdog
# pipeline.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # agent-sdk.sh sources from a relative path; we only need the function,
  # so extract and source it directly without pulling claude_run_with_watchdog
  # dependencies (LOGFILE, log(), etc.) into scope.
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/agent-sdk.sh"
}

# ── Acceptance test from issue #910 ─────────────────────────────────────────

@test "FORGE_TOKEN value is redacted on the way to disk" {
  local payload="FORGE_TOKEN=abc123def456ghi789"
  local out
  out=$(printf '%s\n' "$payload" | redact_log_secrets)
  [ "$out" = "FORGE_TOKEN=<redacted>" ]
}

# ── Variants of the well-known prefix list ──────────────────────────────────

@test "FORGE_ARCHITECT_TOKEN (multi-segment name) is redacted" {
  local out
  out=$(printf 'FORGE_ARCHITECT_TOKEN=secret_value_xyz\n' | redact_log_secrets)
  [ "$out" = "FORGE_ARCHITECT_TOKEN=<redacted>" ]
}

@test "GITHUB_TOKEN is redacted" {
  local out
  out=$(printf 'GITHUB_TOKEN=ghp_aaaaaaaaaaaaaaaa\n' | redact_log_secrets)
  [ "$out" = "GITHUB_TOKEN=<redacted>" ]
}

@test "GH_TOKEN is redacted" {
  local out
  out=$(printf 'GH_TOKEN=ghp_short\n' | redact_log_secrets)
  [ "$out" = "GH_TOKEN=<redacted>" ]
}

@test "VAULT_PASS is redacted" {
  local out
  out=$(printf 'VAULT_PASS=hunter2hunter2\n' | redact_log_secrets)
  [ "$out" = "VAULT_PASS=<redacted>" ]
}

@test "CLAW_API_KEY is redacted" {
  local out
  out=$(printf 'CLAW_API_KEY=clw_deadbeef\n' | redact_log_secrets)
  [ "$out" = "CLAW_API_KEY=<redacted>" ]
}

@test "ANTHROPIC_API_KEY is redacted" {
  local out
  out=$(printf 'ANTHROPIC_API_KEY=sk-ant-aaaa1111\n' | redact_log_secrets)
  [ "$out" = "ANTHROPIC_API_KEY=<redacted>" ]
}

# ── Realistic JSONL line (the actual #910 leak path) ────────────────────────

@test "FORGE_TOKEN inside a JSON-embedded tool_result is redacted" {
  # This mimics what gets written when claude's bash tool runs `env | grep -i forge`
  # and stream-json wraps the stdout in a tool_result message.
  local line='{"type":"tool_result","content":"FORGE_ARCHITECT_TOKEN=abc123def456ghi789jkl"}'
  local out
  out=$(printf '%s\n' "$line" | redact_log_secrets)
  [ "$out" = '{"type":"tool_result","content":"FORGE_ARCHITECT_TOKEN=<redacted>"}' ]
}

@test "multiple secrets on the same line are all redacted" {
  local line='FORGE_TOKEN=aaa GITHUB_TOKEN=bbb'
  local out
  out=$(printf '%s\n' "$line" | redact_log_secrets)
  [ "$out" = "FORGE_TOKEN=<redacted> GITHUB_TOKEN=<redacted>" ]
}

# ── Negative cases — must NOT redact ────────────────────────────────────────

@test "non-secret KEY=value is left untouched" {
  local out
  out=$(printf 'PRIMARY_BRANCH=main\n' | redact_log_secrets)
  [ "$out" = "PRIMARY_BRANCH=main" ]
}

@test "FORGE_API URL is NOT redacted (no TOKEN/PASS/KEY/SECRET suffix)" {
  local out
  out=$(printf 'FORGE_API=http://localhost:3000/api/v1\n' | redact_log_secrets)
  [ "$out" = "FORGE_API=http://localhost:3000/api/v1" ]
}

@test "shell variable reference \$FORGE_TOKEN (no =) is left untouched" {
  local out
  out=$(printf 'curl -H "Authorization: token $FORGE_TOKEN"\n' | redact_log_secrets)
  [ "$out" = 'curl -H "Authorization: token $FORGE_TOKEN"' ]
}

# ── Case-insensitive matching ───────────────────────────────────────────────

@test "lowercase forge_token=… is also redacted (case-insensitive)" {
  local out
  out=$(printf 'forge_token=lowercase_value\n' | redact_log_secrets)
  [ "$out" = "forge_token=<redacted>" ]
}
