#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1852.sh
#
# Issue #1852: docker/agents/entrypoint.sh checks for the claude CLI and a
# login only when AGENT_HARNESS=claude. dsh is the default (#1683), so an
# agent with the variable empty or set to dsh must skip the gate even when
# claude is missing. AGENT_REQUIRES_CLAUDE is gone.
#
# Hermetic: no container, no network, no Claude. The gate is cut out between
# the two comments the issue names and eval'd under env -i. Stubs are written
# inline and are not copied from another acceptance test.
#
# Run via: tools/run-acceptance.sh 1852
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep mktemp

entrypoint_path="${REPO_ROOT}/docker/agents/entrypoint.sh"
ac_assert_file "$entrypoint_path" "agents entrypoint must exist for the #1852 gate cut"

requires_hits="$(grep -c 'AGENT_REQUIRES_CLAUDE' "$entrypoint_path" || true)"
ac_assert_eq "$requires_hits" "0" \
  "AGENT_REQUIRES_CLAUDE must be gone from the agents entrypoint (count=${requires_hits})"

gate_body="$(awk '/^# Claude CLI auth gate/{f=1} /^# Bootstrap ops repos/{f=0} f' "$entrypoint_path")"
[ -n "$gate_body" ] || ac_fail "awk cut of the Claude CLI auth gate was empty"
case "$gate_body" in
  *"AGENT_HARNESS:-}"*) ;;
  *) ac_fail "extracted gate does not test \${AGENT_HARNESS:-}" ;;
esac
case "$gate_body" in
  *"AGENT_HARNESS:-dsh"*|*"AGENT_HARNESS:-claude"*)
    ac_fail "extracted gate must not use AGENT_HARNESS:-dsh or AGENT_HARNESS:-claude"
    ;;
esac

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/issue-1852-gate.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "${sandbox}/bin"
marker="${sandbox}/claude-ran"
interpreter="$(command -v bash)"

# Skip-path stand-in: if the gate still execs claude, it leaves a marker.
cat > "${sandbox}/bin/claude" << EOF
#!/bin/sh
touch '${marker}'
printf '%s\n' 'issue-1852 skip-stub was executed'
exit 3
EOF
chmod 0755 "${sandbox}/bin/claude"

# harness_value may be empty. Extra env pairs are appended only for the
# logged-in claude case so the skip/fatal runs stay env -i plus PATH/GATE.
fire_gate() {
  local harness_value="$1"
  local transcript="$2"
  shift 2
  local status=0
  # shellcheck disable=SC2016  # GATE is expanded by the child bash, not this one
  env -i \
    PATH="${sandbox}/bin" \
    AGENT_HARNESS="$harness_value" \
    GATE="$gate_body" \
    "$@" \
    "$interpreter" -c 'log() { echo "$*"; }; eval "$GATE"' \
    >"$transcript" 2>"${transcript}.err" || status=$?
  printf '%s' "$status"
}

ac_log "empty AGENT_HARNESS skips the gate and does not exec claude"
rm -f "$marker"
empty_transcript="${sandbox}/empty.out"
empty_status="$(fire_gate "" "$empty_transcript")"
ac_assert_eq "$empty_status" "0" \
  "empty AGENT_HARNESS must exit 0 (got ${empty_status}); err=$(cat "${empty_transcript}.err")"
grep -qF 'Claude auth gate: skipped' "$empty_transcript" \
  || ac_fail "empty AGENT_HARNESS did not print the skip line: $(cat "$empty_transcript")"
if [ -e "$marker" ]; then
  ac_fail "empty AGENT_HARNESS executed claude (${marker} exists)"
fi

ac_log "AGENT_HARNESS=dsh skips the gate and does not exec claude"
rm -f "$marker"
dsh_transcript="${sandbox}/dsh.out"
dsh_status="$(fire_gate "dsh" "$dsh_transcript")"
ac_assert_eq "$dsh_status" "0" \
  "AGENT_HARNESS=dsh must exit 0 (got ${dsh_status}); err=$(cat "${dsh_transcript}.err")"
grep -qF 'Claude auth gate: skipped (AGENT_HARNESS is not claude)' "$dsh_transcript" \
  || ac_fail "dsh skip line mismatch: $(cat "$dsh_transcript")"
if [ -e "$marker" ]; then
  ac_fail "AGENT_HARNESS=dsh executed claude (${marker} exists)"
fi

ac_log "AGENT_HARNESS=claude with no CLI is fatal"
rm -f "${sandbox}/bin/claude" "$marker"
fatal_transcript="${sandbox}/fatal.out"
fatal_status="$(fire_gate "claude" "$fatal_transcript")"
ac_assert_eq "$fatal_status" "1" \
  "missing claude CLI must exit 1 (got ${fatal_status}); out=$(cat "$fatal_transcript")"
grep -qF 'FATAL: claude CLI not found in PATH.' "$fatal_transcript" \
  || ac_fail "fatal line missing: $(cat "$fatal_transcript")"

ac_log "AGENT_HARNESS=claude with a version stub and an API key passes"
cat > "${sandbox}/bin/claude" << 'EOF'
#!/bin/sh
if [ "${1-}" = "--version" ]; then
  printf '%s\n' 'claude 9.9.9 (stub)'
  exit 0
fi
printf 'issue-1852 version stub rejected argv: %s\n' "$*" >&2
exit 4
EOF
chmod 0755 "${sandbox}/bin/claude"
version_transcript="${sandbox}/version.out"
version_status="$(fire_gate "claude" "$version_transcript" ANTHROPIC_API_KEY=x)"
ac_assert_eq "$version_status" "0" \
  "claude harness with API key must exit 0 (got ${version_status}); err=$(cat "${version_transcript}.err") out=$(cat "$version_transcript")"
grep -qF 'Claude CLI: claude 9.9.9 (stub)' "$version_transcript" \
  || ac_fail "version line missing: $(cat "$version_transcript")"

ac_log "issue-1682 acceptance still passes, and the entrypoint parses"
sibling_status=0
sibling_transcript="${sandbox}/issue-1682.out"
bash "${REPO_ROOT}/tests/acceptance/issue-1682.sh" >"$sibling_transcript" 2>&1 || sibling_status=$?
ac_assert_eq "$sibling_status" "0" \
  "tests/acceptance/issue-1682.sh must exit 0 (got ${sibling_status}): $(cat "$sibling_transcript")"
grep -qx 'PASS' "$sibling_transcript" \
  || ac_fail "issue-1682.sh did not print a bare PASS line: $(cat "$sibling_transcript")"
bash -n "$entrypoint_path" \
  || ac_fail "bash -n failed on docker/agents/entrypoint.sh"

ac_pass
