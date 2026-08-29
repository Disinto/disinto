#!/usr/bin/env bats
# =============================================================================
# tests/hire-an-agent-nomad.bats — Tests for the Nomad backend of
#   disinto hire-an-agent (#1073)
#
# Covers:
#   1. The rendered jobspec derives FORGE_REPO / FACTORY_REPO / CLAUDE_TIMEOUT
#      / CLAUDE_MAX_TURNS / CLAUDE_AUTOCOMPACT_PCT_OVERRIDE from the
#      environment rather than hardcoding the disinto factory's own values.
#   2. Those values fall back to the same defaults the compose backend uses
#      (lib/generators.sh).
#   3. The jobspec carries the identifiers and mounts the entrypoint needs.
#   4. The deploy is refused — not attempted — when the bot's Vault role is
#      not in place, because the jobspec declares vault { role = ... } and the
#      task would otherwise crash-loop on the secret exchange.
#   5. `nomad job validate` is run before `nomad job run`.
#
# The Vault and Nomad CLIs are stubbed, so these tests need neither.
# =============================================================================

setup_file() {
  export DISINTO_ROOT
  DISINTO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export HIRE_LIB="${DISINTO_ROOT}/lib/hire-agent.sh"
  [ -f "$HIRE_LIB" ] || {
    echo "hire-agent.sh not found: $HIRE_LIB" >&2
    return 1
  }
}

setup() {
  TMP="$(mktemp -d)"
  export TMP
  export FACTORY_ROOT="$TMP/factory"
  mkdir -p "$FACTORY_ROOT/lib" "$TMP/bin"

  # `nomad` stub: record the jobspec handed to validate/run so the test can
  # assert on what would actually be deployed.
  cat > "$TMP/bin/nomad" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "job validate") echo "validate" >> "$NOMAD_CALLS"; cp "$3" "$JOBSPEC_OUT"; exit 0 ;;
  "job run")      echo "run" >> "$NOMAD_CALLS"; cp "${@: -1}" "$JOBSPEC_OUT"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/nomad"
  export PATH="$TMP/bin:$PATH"
  export NOMAD_CALLS="$TMP/nomad-calls"
  export JOBSPEC_OUT="$TMP/jobspec.hcl"
  : > "$NOMAD_CALLS"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# A Vault stub whose role checks succeed, so rendering can be exercised.
_stub_vault_ok() {
  cat > "$FACTORY_ROOT/lib/hvault.sh" <<'STUB'
_hvault_default_env() { :; }
hvault_token_lookup() { return 0; }
hvault_get_or_empty() { echo ""; }
hvault_policy_apply()  { return 0; }
_hvault_request() { return 0; }
STUB
}

# Render a jobspec by invoking the real helper with the CLIs stubbed.
_render() {
  # The helper calls `exit` on its refusal path, which terminates the
  # subshell — so capture the subshell's status from outside it, and always
  # return 0 so the caller can assert on rc rather than aborting the test.
  local rc=0
  # shellcheck source=/dev/null
  ( set +e
    source "$HIRE_LIB" 2>/dev/null
    disinto_hire_an_agent_nomad \
      "labbot" "dev" "http://10.0.0.1:8081" "qwen" "300" "lab" "tok" "pw" \
      >"$TMP/stdout" 2>"$TMP/stderr"
  ) || rc=$?
  echo "${rc:-0}" > "$TMP/rc"
  return 0
}

# ── derived configuration ─────────────────────────────────────────────────────

@test "rendered jobspec derives FORGE_REPO and FACTORY_REPO from the environment" {
  _stub_vault_ok
  export FORGE_REPO="acme/lab"
  _render
  [ -f "$JOBSPEC_OUT" ]
  grep -q 'FORGE_REPO *= *"acme/lab"' "$JOBSPEC_OUT"
  grep -q 'FACTORY_REPO *= *"acme/lab"' "$JOBSPEC_OUT"
  # the factory's own repo must not be baked in
  ! grep -q 'FORGE_REPO *= *"disinto-admin/disinto"' "$JOBSPEC_OUT"
}

@test "FACTORY_REPO can differ from FORGE_REPO" {
  _stub_vault_ok
  export FORGE_REPO="acme/lab"
  export FACTORY_REPO="acme/factory"
  _render
  grep -q 'FORGE_REPO *= *"acme/lab"' "$JOBSPEC_OUT"
  grep -q 'FACTORY_REPO *= *"acme/factory"' "$JOBSPEC_OUT"
}

@test "claude tuning values are derived, not hardcoded" {
  _stub_vault_ok
  export CLAUDE_TIMEOUT="3600"
  export CLAUDE_MAX_TURNS="120"
  export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="50"
  _render
  grep -q 'CLAUDE_TIMEOUT *= *"3600"' "$JOBSPEC_OUT"
  grep -q 'CLAUDE_MAX_TURNS *= *"120"' "$JOBSPEC_OUT"
  grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE *= *"50"' "$JOBSPEC_OUT"
}

@test "defaults match the compose backend when nothing is set" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render
  grep -q 'FORGE_REPO *= *"disinto-admin/disinto"' "$JOBSPEC_OUT"
  grep -q 'CLAUDE_TIMEOUT *= *"7200"' "$JOBSPEC_OUT"
  grep -q 'CLAUDE_MAX_TURNS *= *"60"' "$JOBSPEC_OUT"
  grep -q 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE *= *"60"' "$JOBSPEC_OUT"
}

# ── jobspec shape ─────────────────────────────────────────────────────────────

@test "jobspec carries the bot identifiers, role and project paths" {
  _stub_vault_ok
  _render
  grep -q 'job "bot-labbot"' "$JOBSPEC_OUT"
  grep -q 'role *= *"bot-labbot"' "$JOBSPEC_OUT"
  grep -q 'AGENT_ROLES *= *"dev"' "$JOBSPEC_OUT"
  grep -q 'POLL_INTERVAL *= *"300"' "$JOBSPEC_OUT"
  grep -q 'PROJECT_NAME *= *"lab"' "$JOBSPEC_OUT"
  grep -q 'PROJECT_REPO_ROOT *= *"/home/agent/repos/lab"' "$JOBSPEC_OUT"
  grep -q 'ANTHROPIC_BASE_URL *= *"http://10.0.0.1:8081"' "$JOBSPEC_OUT"
}

@test "jobspec mounts the four host volumes the entrypoint expects" {
  _stub_vault_ok
  _render
  for v in agent-data project-repos ops-repo factory-projects; do
    grep -q "volume \"$v\"" "$JOBSPEC_OUT"
  done
  grep -q '/srv/disinto/project-repos/_factory/projects' "$JOBSPEC_OUT"
}

@test "jobspec is validated before it is run" {
  _stub_vault_ok
  _render
  [ "$(head -1 "$NOMAD_CALLS")" = "validate" ]
  grep -q '^run$' "$NOMAD_CALLS"
}

# ── Vault role is a precondition, not a warning ───────────────────────────────

@test "deploy is refused when the bot Vault role is not in place" {
  # No hvault.sh at all -> Vault unreachable -> role never confirmed.
  _render
  [ "$(cat "$TMP/rc")" != "0" ]
  grep -q "refusing to deploy" "$TMP/stderr"
  # and nothing was handed to nomad
  [ ! -s "$NOMAD_CALLS" ]
}

@test "the refusal explains the crash-loop it prevents" {
  _render
  grep -q "crash-loop" "$TMP/stderr"
  grep -qi "vault role" "$TMP/stderr"
}
