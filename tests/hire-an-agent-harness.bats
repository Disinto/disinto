#!/usr/bin/env bats
# =============================================================================
# tests/hire-an-agent-harness.bats — #1107: `--harness` flag to hire either a
#   Claude or a dsh agent.
#
# Covers:
#   1. The default (no --harness) and an explicit `--harness claude` hire
#      render byte-identical output to the pre-#1107 code, pinned by fixtures
#      captured from the pre-change implementation.
#   2. `--harness dsh` emits dsh's own settings-form variables (AGENT_HARNESS,
#      DSH_HOME, DSH_PERMISSION_MODE, DSH_MODEL, DSH_BASE_URL,
#      DSH_CONTEXT_WINDOW) and no CLAUDE_* / ANTHROPIC_* tuning variables —
#      on both the Nomad and the compose backend.
#   3. --context-window defaults to 163840, is overridable, and is validated
#      as a positive integer.
#   4. An invalid --harness is rejected with a clear message and a non-zero
#      exit, before any side effect (no TOML written).
#
# The Vault and Nomad CLIs are stubbed, so these tests need neither.
# =============================================================================

setup_file() {
  export DISINTO_ROOT
  DISINTO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export HIRE_LIB="${DISINTO_ROOT}/lib/hire-agent.sh"
  export GENERATORS_LIB="${DISINTO_ROOT}/lib/generators.sh"
  export FIXTURES="${DISINTO_ROOT}/tests/fixtures/hire-an-agent-harness"
  [ -f "$HIRE_LIB" ] || { echo "hire-agent.sh not found: $HIRE_LIB" >&2; return 1; }
  [ -f "$FIXTURES/jobspec-default.hcl" ] || {
    echo "fixture missing: $FIXTURES/jobspec-default.hcl" >&2
    return 1
  }
  [ -f "$FIXTURES/compose-default.yml" ] || {
    echo "fixture missing: $FIXTURES/compose-default.yml" >&2
    return 1
  }
}

setup() {
  TMP="$(mktemp -d)"
  export TMP
  export FACTORY_ROOT="$TMP/factory"
  mkdir -p "$FACTORY_ROOT/lib" "$FACTORY_ROOT/projects" "$TMP/bin"

  # Minimal compose skeleton `_generate_local_model_services` can splice into
  # (must match the fixture capture exactly).
  cat > "$FACTORY_ROOT/docker-compose.yml" <<'EOF'
services:
  agents:
    image: placeholder

volumes:
  agent-data:
EOF

  # `nomad` stub: record the calls and capture the jobspec handed to
  # validate/run so the test can assert on what would actually be deployed.
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

# Render a Nomad jobspec by invoking the real helper with the CLIs stubbed.
# $1 = harness ("" exercises the helper's default), $2 = context window.
# The helper calls `exit` on its refusal path, which terminates the subshell
# — capture the subshell's status from outside it, and always return 0 so the
# caller can assert on rc rather than aborting the test.
_render_nomad() {
  local rc=0
  # shellcheck source=/dev/null
  ( set +e
    source "$HIRE_LIB" 2>/dev/null
    disinto_hire_an_agent_nomad \
      "labbot" "dev" "http://10.0.0.1:8081" "qwen" "300" "lab" "tok" "pw" \
      "${1:-}" "${2:-}" \
      >"$TMP/stdout" 2>"$TMP/stderr"
  ) || rc=$?
  echo "${rc:-0}" > "$TMP/rc"
  return 0
}

# Run the full `disinto hire-an-agent` entry point in a subshell so its
# `exit` on the validation paths cannot kill the test; capture rc + stderr.
_run_hire() {
  local rc=0
  ( set +e
    # shellcheck source=/dev/null
    source "$HIRE_LIB" 2>/dev/null
    disinto_hire_an_agent "$@" >"$TMP/hire-stdout" 2>"$TMP/hire-stderr"
  ) || rc=$?
  echo "${rc:-0}" > "$TMP/hire-rc"
  return 0
}

# Run the compose generator against the fixture-matching skeleton, with the
# env vars the fixture was captured without explicitly cleared.
_generate_compose() {
  run bash -c "
    set -euo pipefail
    unset FORGE_REPO PROJECT_NAME ARCHITECT_INTERVAL PLANNER_INTERVAL SUPERVISOR_INTERVAL
    source '${GENERATORS_LIB}'
    _generate_local_model_services '${FACTORY_ROOT}/docker-compose.yml'
  "
  [ "$status" -eq 0 ]
}

# The project TOML the compose fixtures were captured with: a default
# (claude-harness) local-model agent, no harness keys at all.
_write_default_toml() {
  cat > "$FACTORY_ROOT/projects/test.toml" <<'EOF'
[agents.llama]
base_url      = "http://10.10.10.1:8081"
model         = "qwen"
api_key       = "sk-no-key-required"
roles         = ["dev"]
forge_user    = "dev-qwen"
compact_pct   = 60
poll_interval = 60
EOF
}

# ── byte-identical default (both backends) ───────────────────────────────────

@test "default nomad hire renders the pre-#1107 jobspec byte for byte" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad
  [ "$(cat "$TMP/rc")" = "0" ]
  cmp -s "$JOBSPEC_OUT" "$FIXTURES/jobspec-default.hcl"
}

@test "explicit claude harness renders the same jobspec as the default" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad claude
  [ "$(cat "$TMP/rc")" = "0" ]
  cmp -s "$JOBSPEC_OUT" "$FIXTURES/jobspec-default.hcl"
}

@test "default compose hire renders the pre-#1107 service byte for byte" {
  _write_default_toml
  _generate_compose
  cmp -s "$FACTORY_ROOT/docker-compose.yml" "$FIXTURES/compose-default.yml"
}

# ── dsh harness (both backends) ──────────────────────────────────────────────

@test "dsh nomad hire emits dsh's settings-form environment" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad dsh
  [ "$(cat "$TMP/rc")" = "0" ]
  grep -Eq 'AGENT_HARNESS[[:space:]]*=[[:space:]]*"dsh"' "$JOBSPEC_OUT"
  grep -Eq 'DSH_HOME[[:space:]]*=[[:space:]]*"/home/agent/data/dsh"' "$JOBSPEC_OUT"
  grep -Eq 'DSH_PERMISSION_MODE[[:space:]]*=[[:space:]]*"danger-full-access"' "$JOBSPEC_OUT"
  grep -Eq 'DSH_MODEL[[:space:]]*=[[:space:]]*"qwen"' "$JOBSPEC_OUT"
  grep -Eq 'DSH_BASE_URL[[:space:]]*=[[:space:]]*"http://10\.0\.0\.1:8081"' "$JOBSPEC_OUT"
  grep -Eq 'DSH_CONTEXT_WINDOW[[:space:]]*=[[:space:]]*"163840"' "$JOBSPEC_OUT"
}

@test "dsh nomad hire emits no CLAUDE_* or ANTHROPIC_* tuning variables" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad dsh
  [ "$(cat "$TMP/rc")" = "0" ]
  ! grep -Eq 'CLAUDE_|ANTHROPIC_' "$JOBSPEC_OUT"
}

@test "--context-window overrides the dsh window in the nomad jobspec" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad dsh 200000
  [ "$(cat "$TMP/rc")" = "0" ]
  grep -Eq 'DSH_CONTEXT_WINDOW[[:space:]]*=[[:space:]]*"200000"' "$JOBSPEC_OUT"
}

@test "dsh compose service emits dsh's settings-form environment and no CLAUDE_* tuning" {
  cat > "$FACTORY_ROOT/projects/test.toml" <<'EOF'
[agents.dshbot]
base_url       = "http://10.10.10.1:8081"
model          = "qwen"
api_key        = "sk-no-key-required"
roles          = ["dev"]
forge_user     = "dev-dsh"
compact_pct    = 60
poll_interval  = 60
harness        = "dsh"
context_window = 200000
EOF
  _generate_compose
  grep -q 'AGENT_HARNESS: "dsh"' "$FACTORY_ROOT/docker-compose.yml"
  grep -q 'DSH_HOME: /home/agent/data/dsh' "$FACTORY_ROOT/docker-compose.yml"
  grep -q 'DSH_PERMISSION_MODE: "danger-full-access"' "$FACTORY_ROOT/docker-compose.yml"
  grep -q 'DSH_MODEL: "qwen"' "$FACTORY_ROOT/docker-compose.yml"
  grep -q 'DSH_BASE_URL: "http://10.10.10.1:8081"' "$FACTORY_ROOT/docker-compose.yml"
  grep -q 'DSH_CONTEXT_WINDOW: "200000"' "$FACTORY_ROOT/docker-compose.yml"
  # Scope to the service's environment: block — the service still mounts the
  # CLAUDE_SHARED_DIR / CLAUDE_CONFIG_FILE volumes, which must not count.
  local env_block
  env_block="$(awk '
    /^  agents-dshbot:/ { f = 1 }
    f && /^    environment:/ { e = 1; next }
    f && e && /^    depends_on:/ { e = 0 }
    f && e
  ' "$FACTORY_ROOT/docker-compose.yml")"
  [ -n "$env_block" ]
  ! grep -Eq 'CLAUDE_|ANTHROPIC_' <<<"$env_block"
}

@test "dsh compose service without context_window defaults to 163840" {
  cat > "$FACTORY_ROOT/projects/test.toml" <<'EOF'
[agents.dshbot]
base_url      = "http://10.10.10.1:8081"
model         = "qwen"
api_key       = "sk-no-key-required"
roles         = ["dev"]
forge_user    = "dev-dsh"
compact_pct   = 60
poll_interval = 60
harness       = "dsh"
EOF
  _generate_compose
  grep -q 'DSH_CONTEXT_WINDOW: "163840"' "$FACTORY_ROOT/docker-compose.yml"
}

# ── flag validation ──────────────────────────────────────────────────────────

@test "invalid --harness is rejected with a clear error and no side effects" {
  _run_hire "testbot" "dev" \
    --local-model "http://10.0.0.1:8081" --model qwen --harness bogus
  [ "$(cat "$TMP/hire-rc")" != "0" ]
  grep -q "Error: invalid --harness value 'bogus'" "$TMP/hire-stderr"
  grep -q "The harness must be 'claude' (default) or 'dsh'" "$TMP/hire-stderr"
  # ... and nothing was written to the projects dir.
  [ -z "$(ls -A "$FACTORY_ROOT/projects")" ]
}

@test "--context-window must be a positive integer" {
  _run_hire "testbot" "dev" \
    --local-model "http://10.0.0.1:8081" --model qwen --harness dsh --context-window 0
  [ "$(cat "$TMP/hire-rc")" != "0" ]
  grep -q "Error: --context-window must be a positive integer of tokens" "$TMP/hire-stderr"

  _run_hire "testbot" "dev" \
    --local-model "http://10.0.0.1:8081" --model qwen --harness dsh --context-window abc
  [ "$(cat "$TMP/hire-rc")" != "0" ]
  grep -q "Error: --context-window must be a positive integer of tokens" "$TMP/hire-stderr"
  [ -z "$(ls -A "$FACTORY_ROOT/projects")" ]
}
