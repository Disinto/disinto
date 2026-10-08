#!/usr/bin/env bats
# DSH_CONTEXT_WINDOW also appears in nomad/jobs/agents-*-grok.hcl (200000, set by hand
# for Grok, 2026-10-03); hire-an-agent's default stays 100000.
# =============================================================================
# tests/hire-an-agent-harness.bats — #1107: `--harness` flag to hire either a
#   Claude or a dsh agent.
#
# Covers:
#   1. Nomad: the default (no harness argument) emits AGENT_HARNESS=dsh,
#      pinned by jobspec-default.hcl; an explicit `--harness dsh` renders the
#      same jobspec. An explicit `--harness claude` emits AGENT_HARNESS=claude
#      plus the CLAUDE_* block, pinned by jobspec-claude.hcl. Neither omits
#      AGENT_HARNESS (#1683: omission means dsh).
#      Compose: the generator pin (a key-less TOML, `_write_default_toml`)
#      now emits a dsh service (AGENT_HARNESS: "dsh"), pinned by
#      compose-default.yml; an explicit harness = "claude" emits the claude
#      service, pinned by compose-claude.yml (#1854).
#   2. `--harness dsh` emits dsh's own settings-form variables (AGENT_HARNESS,
#      DSH_HOME, DSH_PERMISSION_MODE, DSH_MODEL, DSH_BASE_URL,
#      DSH_CONTEXT_WINDOW) and no CLAUDE_* / ANTHROPIC_* tuning variables —
#      on both the Nomad and the compose backend.
#   3. --context-window defaults to 100000, is overridable, and is validated
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
  [ -f "$FIXTURES/jobspec-claude.hcl" ] || {
    echo "fixture missing: $FIXTURES/jobspec-claude.hcl" >&2
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

  # Compose skeleton `_generate_local_model_services` splices into (must
  # match the fixture capture exactly). The volumes section is the real
  # 5-entry block the init generator emits — with a single-entry block the
  # per-agent volume append path is never exercised (the sed/python loop
  # hits EOF before appending), so the fixture would not pin it.
  cat > "$FACTORY_ROOT/docker-compose.yml" <<'EOF'
services:
  agents:
    image: placeholder

volumes:
  forgejo-data:
  woodpecker-data:
  agent-data:
  project-repos:
  caddy_data:
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
    unset FORGE_REPO PROJECT_NAME
    source '${GENERATORS_LIB}'
    _generate_local_model_services '${FACTORY_ROOT}/docker-compose.yml'
  "
  [ "$status" -eq 0 ]
}

# The key-less project TOML the compose fixtures are captured from: a
# local-model agent with no harness key in the section. Since #1854 the
# generator turns a key-less section into a dsh service, so the fixture
# pins AGENT_HARNESS: "dsh" (unset AGENT_HARNESS is dsh, #1683).
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

@test "default nomad hire emits AGENT_HARNESS=dsh" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad
  [ "$(cat "$TMP/rc")" = "0" ]
  cmp -s "$JOBSPEC_OUT" "$FIXTURES/jobspec-default.hcl"
  grep -Eq 'AGENT_HARNESS[[:space:]]*=[[:space:]]*"dsh"' "$JOBSPEC_OUT"
}

@test "explicit dsh harness renders the same jobspec as the default" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad dsh
  [ "$(cat "$TMP/rc")" = "0" ]
  cmp -s "$JOBSPEC_OUT" "$FIXTURES/jobspec-default.hcl"
}

@test "explicit claude harness renders the claude jobspec" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad claude
  [ "$(cat "$TMP/rc")" = "0" ]
  cmp -s "$JOBSPEC_OUT" "$FIXTURES/jobspec-claude.hcl"
}

@test "a section without a harness key generates a dsh service" {
  _write_default_toml
  _generate_compose
  cmp -s "$FACTORY_ROOT/docker-compose.yml" "$FIXTURES/compose-default.yml"
  grep -q 'AGENT_HARNESS: "dsh"' "$FACTORY_ROOT/docker-compose.yml"
}

@test "harness = claude generates the claude service" {
  cat > "$FACTORY_ROOT/projects/test.toml" <<'EOF'
[agents.llama]
base_url      = "http://10.10.10.1:8081"
model         = "qwen"
api_key       = "sk-no-key-required"
roles         = ["dev"]
forge_user    = "dev-qwen"
compact_pct   = 60
poll_interval = 60
harness       = "claude"
EOF
  _generate_compose
  cmp -s "$FACTORY_ROOT/docker-compose.yml" "$FIXTURES/compose-claude.yml"
  grep -q 'AGENT_HARNESS: "claude"' "$FACTORY_ROOT/docker-compose.yml"
}

@test "the hire writes the harness key for both harnesses" {
  # The inline python the hire rewrites the TOML with: extract it (the lines
  # between `    python3 -c '` and the line starting with `' "$toml_file"`)
  # and drive it against two hand-made sections, harness dsh vs claude.
  #
  # That python imports tomlkit, a real dependency of every hire (lib/
  # hire-agent.sh uses it to round-trip the project TOML), but the bats
  # Alpine image does not ship it (apk list: bash bats jq curl git python3
  # py3-yaml unzip age sops zstd — no py3-tomlkit). Rather than add a package
  # to the apk list — which would risk failing the whole bats step if the
  # community-repo package is absent or misnamed — this test supplies a
  # minimal tomlkit implementing only the subset the hire python uses (parse /
  # table / add / subscript / dumps) via PYTHONPATH. The conditional logic
  # under test — "always write harness; write context_window only when
  # harness == dsh" — lives in the extracted, unmodified python and is
  # exercised verbatim; only the TOML round-trip is stand-in.
  local prog stubdir
  prog=$(awk '/^    python3 -c /{f=1; next} /^'"'"' "\$toml_file"/{exit} f' "$HIRE_LIB")
  [ -n "$prog" ]
  local t_dsh t_claude
  t_dsh=$(mktemp)
  t_claude=$(mktemp)
  stubdir=$(mktemp -d)
  trap 'rm -f "$t_dsh" "$t_claude"; rm -rf "$stubdir"' RETURN
  # The parsed document only needs to be a nested dict the python can assign
  # into (agents -> section -> keys); the section it replaces is what the
  # assertions read, so the parser may ignore the input lines.
  cat > "$stubdir/tomlkit.py" <<'STUB'
class _Table(dict):
    def add(self, name, value):
        self[name] = value


def _scalar(v):
    if isinstance(v, list):
        return "[" + ", ".join(_scalar(x) for x in v) + "]"
    if isinstance(v, (int, float)) or v in (None, True, False):
        return str(v)
    return '"' + str(v).replace('"', '\\"') + '"'


def _dump(obj, name=None):
    lines = []
    if name is not None:
        lines.append("[" + name + "]")
    for k, v in obj.items():
        if isinstance(v, dict) and v:
            lines.append(_dump(v, k))
        else:
            lines.append(k + " = " + _scalar(v))
    return "\n".join(lines)


def parse(text):
    return _Table()


def table():
    return _Table()


def dumps(obj):
    return _dump(obj) + "\n"
STUB
  cat > "$t_dsh" <<'TOML'
[agents.lab]
base_url = "http://10.0.0.1:8081"
model = "qwen"
api_key = "sk-no-key-required"
roles = ["dev"]
forge_user = "labbot"
compact_pct = 60
poll_interval = 60
TOML
  cp "$t_dsh" "$t_claude"
  PYTHONPATH="$stubdir" python3 -c "$prog" "$t_dsh" labbot "http://10.0.0.1:8081" qwen lab dev 60 dsh 100000
  grep -q '^harness = "dsh"' "$t_dsh"
  grep -q '^context_window = 100000$' "$t_dsh"
  PYTHONPATH="$stubdir" python3 -c "$prog" "$t_claude" labbot "http://10.0.0.1:8081" qwen lab dev 60 claude 100000
  grep -q '^harness = "claude"' "$t_claude"
  # Final assertion: the claude path must not carry a context window.
  ! grep -qE '^context_window = ' "$t_claude"
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
  grep -Eq 'DSH_CONTEXT_WINDOW[[:space:]]*=[[:space:]]*"100000"' "$JOBSPEC_OUT"
}

@test "dsh nomad hire emits no CLAUDE_* or ANTHROPIC_* tuning variables" {
  _stub_vault_ok
  unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  _render_nomad dsh
  [ "$(cat "$TMP/rc")" = "0" ]
  ! grep -Eq 'CLAUDE_|ANTHROPIC_' "$JOBSPEC_OUT"
}

@test "stock qwen jobspecs pin DSH_CONTEXT_WINDOW to the default 100000" {
  # The stock per-role qwen jobspecs (agents.hcl was retired for qwen roles)
  # hard-code the dsh env; pin the context window there too, so a move of
  # the default in lib/hire-agent.sh breaks here and in CI in the same PR
  # (defaults-golden contract, #1261).
  for f in nomad/jobs/agents-dev-qwen.hcl \
           nomad/jobs/agents-review-qwen.hcl \
           nomad/jobs/agents-gardener-qwen.hcl; do
    [ -f "$DISINTO_ROOT/$f" ] || { echo "missing $f" >&2; return 1; }
    grep -Eq 'DSH_CONTEXT_WINDOW[[:space:]]*=[[:space:]]*"100000"' "$DISINTO_ROOT/$f" \
      || { echo "$f does not pin DSH_CONTEXT_WINDOW 100000" >&2; return 1; }
  done
}

@test "stock grok jobspecs pin DSH_CONTEXT_WINDOW to the hand-set 200000" {
  # The per-role grok jobspecs (Grok 4.7 via the dsh harness) set the context
  # window by hand to 200000, larger than the 100000 dsh default. hire-an-agent
  # and the stock qwen jobspecs keep the 100000 default (see file header). Pin
  # each grok jobspec so a move of the value breaks here and in CI in the same
  # PR (defaults-golden contract, #1261).
  for f in nomad/jobs/agents-dev-grok.hcl \
           nomad/jobs/agents-review-grok.hcl \
           nomad/jobs/agents-architect-grok.hcl \
           nomad/jobs/agents-planner-grok.hcl; do
    [ -f "$DISINTO_ROOT/$f" ] || { echo "missing $f" >&2; return 1; }
    grep -Eq 'DSH_CONTEXT_WINDOW[[:space:]]*=[[:space:]]*"200000"' "$DISINTO_ROOT/$f" \
      || { echo "$f does not pin DSH_CONTEXT_WINDOW 200000" >&2; return 1; }
  done
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

@test "dsh compose service without context_window defaults to 100000" {
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
  grep -q 'DSH_CONTEXT_WINDOW: "100000"' "$FACTORY_ROOT/docker-compose.yml"
}

# ── flag validation ──────────────────────────────────────────────────────────

@test "invalid --harness is rejected with a clear error and no side effects" {
  _run_hire "testbot" "dev" \
    --local-model "http://10.0.0.1:8081" --model qwen --harness bogus
  [ "$(cat "$TMP/hire-rc")" != "0" ]
  grep -q "Error: invalid --harness value 'bogus'" "$TMP/hire-stderr"
  grep -q "The harness must be 'dsh' (default) or 'claude'" "$TMP/hire-stderr"
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
