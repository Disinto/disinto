#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2005.sh
#
# Issue #2005: hire-an-agent --provider sets DSH_PROVIDER in a dsh jobspec.
#
# lib/hire-agent.sh parses `--provider <name>` next to --harness /
# --context-window and validates it before any side effect: it is refused
# with --harness claude, and refused unless the name matches ^[a-z0-9-]+$.
# With the dsh harness the rendered Nomad jobspec then carries
# `DSH_PROVIDER = "<name>"` on the line directly after DSH_BASE_URL — and
# without the flag the jobspec stays byte-identical to
# tests/fixtures/hire-an-agent-harness/jobspec-default.hcl.
#
# Hermetic: the Vault and Nomad CLIs are stubbed exactly as
# tests/hire-an-agent-harness.bats does. No docker, no network, no Vault.
#
# Run via: tools/run-acceptance.sh 2005
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk cmp

HIRE_LIB="$REPO_ROOT/lib/hire-agent.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/hire-an-agent-harness/jobspec-default.hcl"
ac_assert_file "$HIRE_LIB" "lib/hire-agent.sh must exist"
ac_assert_file "$FIXTURE" "fixture missing: tests/fixtures/hire-an-agent-harness/jobspec-default.hcl"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Stub the Nomad CLI (captures the jobspec handed to validate/run) and the
# Vault helper, exactly like tests/hire-an-agent-harness.bats.
BIN="$TMP_DIR/bin"
mkdir -p "$BIN" "$TMP_DIR/factory/lib"
cat > "$BIN/nomad" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "job validate") echo "validate" >> "$NOMAD_CALLS"; cp "$3" "$JOBSPEC_OUT"; exit 0 ;;
  "job run")      echo "run" >> "$NOMAD_CALLS"; cp "${@: -1}" "$JOBSPEC_OUT"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/nomad"
cat > "$TMP_DIR/factory/lib/hvault.sh" <<'STUB'
_hvault_default_env() { :; }
hvault_token_lookup() { return 0; }
hvault_get_or_empty() { echo ""; }
hvault_policy_apply()  { return 0; }
_hvault_request() { return 0; }
STUB

export PATH="$BIN:$PATH"
export FACTORY_ROOT="$TMP_DIR/factory"
export NOMAD_CALLS="$TMP_DIR/nomad-calls"
export JOBSPEC_OUT="$TMP_DIR/jobspec.hcl"
unset FORGE_REPO FACTORY_REPO CLAUDE_TIMEOUT CLAUDE_MAX_TURNS CLAUDE_AUTOCOMPACT_PCT_OVERRIDE

# render <harness> <window> [provider] — render a jobspec through the real
# helper with the CLIs stubbed; RC/OUT/ERR land via ac_run_block.
render() {
  : > "$NOMAD_CALLS"
  ac_run_block "$HIRE_LIB" disinto_hire_an_agent_nomad \
    labbot dev http://10.0.0.1:8081 qwen 300 lab tok pw "$1" "$2" "${3:-}"
}

# Run the full hire entry point in a subshell so its `exit` on the refusal
# paths cannot kill the test; rc in RC, stderr in ERR.
run_hire() {
  RC=0
  ( set +e
    # shellcheck disable=SC1091
    source "$HIRE_LIB" 2>/dev/null
    disinto_hire_an_agent "$@"
  ) >/dev/null 2>"$TMP_DIR/hire-err" || RC=$?
}

ac_log "AC1: --harness dsh --provider xai renders DSH_PROVIDER right after DSH_BASE_URL"
render dsh 100000 xai
ac_assert_eq "$RC" "0" "AC1: rendering exited $RC (stderr: $ERR)"
ac_assert_file "$JOBSPEC_OUT" "AC1: the nomad stub captured no jobspec"
ac_assert_eq "$(grep -c 'DSH_PROVIDER' "$JOBSPEC_OUT")" "1" \
  "AC1: DSH_PROVIDER must appear exactly once"
grep -q 'DSH_PROVIDER *= *"xai"' "$JOBSPEC_OUT" \
  || ac_fail "AC1: jobspec must contain DSH_PROVIDER = \"xai\" (got: $(grep DSH_PROVIDER "$JOBSPEC_OUT"))"
next_line="$(awk '/DSH_BASE_URL/ { getline; print; exit }' "$JOBSPEC_OUT")"
ac_assert_eq "$next_line" '        DSH_PROVIDER        = "xai"' \
  "AC1: DSH_PROVIDER must sit on the line directly after DSH_BASE_URL (got: $next_line)"

ac_log "AC2: without --provider there is no DSH_PROVIDER and the default jobspec is byte-identical"
render "" ""
ac_assert_eq "$RC" "0" "AC2: rendering exited $RC (stderr: $ERR)"
grep -q 'DSH_PROVIDER' "$JOBSPEC_OUT" \
  && ac_fail "AC2: the default jobspec must not carry DSH_PROVIDER"
cmp -s "$JOBSPEC_OUT" "$FIXTURE" \
  || ac_fail "AC2: the default jobspec must stay byte-identical to jobspec-default.hcl"

ac_log "AC3: --harness claude --provider xai is refused before any side effect"
mkdir -p "$FACTORY_ROOT/projects"
: > "$NOMAD_CALLS"
run_hire testbot dev --local-model http://10.0.0.1:8081 --model qwen \
  --harness claude --provider xai
[ "$RC" != 0 ] || ac_fail "AC3: claude + provider must exit non-zero (got 0)"
grep -q -- '--provider' "$TMP_DIR/hire-err" \
  || ac_fail "AC3: the refusal message must name --provider (got: $(cat "$TMP_DIR/hire-err"))"
[ -z "$(ls -A "$FACTORY_ROOT/projects")" ] \
  || ac_fail "AC3: the refusal must happen before any TOML side effect"
[ -s "$NOMAD_CALLS" ] \
  && ac_fail "AC3: the refusal must happen before any nomad call"

ac_log "AC4: --provider '../x' is refused before any side effect"
: > "$NOMAD_CALLS"
run_hire testbot dev --local-model http://10.0.0.1:8081 --model qwen \
  --harness dsh --provider '../x'
[ "$RC" != 0 ] || ac_fail "AC4: a non-[a-z0-9-] provider name must exit non-zero (got 0)"
grep -q -- '--provider' "$TMP_DIR/hire-err" \
  || ac_fail "AC4: the refusal message must name --provider (got: $(cat "$TMP_DIR/hire-err"))"
[ -z "$(ls -A "$FACTORY_ROOT/projects")" ] \
  || ac_fail "AC4: the refusal must happen before any TOML side effect"
[ -s "$NOMAD_CALLS" ] \
  && ac_fail "AC4: the refusal must happen before any nomad call"

ac_log "AC5: the usage line advertises [--provider <name>]"
grep -qF -- '[--provider <name>]' "$HIRE_LIB" \
  || ac_fail "AC5: the hire usage line must list [--provider <name>]"

ac_log "AC6: bash -n passes on lib/hire-agent.sh"
bash -n "$HIRE_LIB" || ac_fail "AC6: bash -n lib/hire-agent.sh failed"

ac_pass