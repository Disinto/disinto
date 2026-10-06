#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1838.sh
#
# Issue #1838: the reproduce/triage/verify sidecar entrypoint runs its agent
# with dsh (sidecar_agent_run), never `claude -p`. The session bound is 60
# minutes. This test only reads files.
#
# Acceptance:
#   1. REPRODUCE_TIMEOUT_MINUTES defaults to 60, and formulas/reproduce.toml
#      sets timeout_minutes = 60.
#   2. entrypoint-reproduce.sh has no claude -p, command -v claude,
#      --mcp-server, CLAUDE_CONFIG_DIR, /usr/local/bin/claude, or "Claude".
#   3. sidecar_agent_run "$CLAUDE_PROMPT" appears twice.
#   4. the sidecar-agent.sh source appears once.
#   5. formulas/reproduce.toml and formulas/triage.toml do not mention claude.
#   6. bash -n docker/reproduce/entrypoint-reproduce.sh succeeds.
#
# Run via: tools/run-acceptance.sh 1838
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

ENTRYPOINT="$REPO_ROOT/docker/reproduce/entrypoint-reproduce.sh"
REPRODUCE_TOML="$REPO_ROOT/formulas/reproduce.toml"
TRIAGE_TOML="$REPO_ROOT/formulas/triage.toml"
ac_assert_file "$ENTRYPOINT" "docker/reproduce/entrypoint-reproduce.sh must exist"
ac_assert_file "$REPRODUCE_TOML" "formulas/reproduce.toml must exist"
ac_assert_file "$TRIAGE_TOML" "formulas/triage.toml must exist"

# grep -c exits 1 when the count is 0; the script is set -e, so tolerate that.
ac_log "AC 1: sidecar timeout default is 60 minutes"
timeout_count="$(grep -cF 'REPRODUCE_TIMEOUT_MINUTES:-60' "$ENTRYPOINT" || true)"
ac_assert_eq "$timeout_count" "1" \
  "REPRODUCE_TIMEOUT_MINUTES:-60 must appear once (got $timeout_count)"
formula_timeout="$(grep -cE '^timeout_minutes = 60$' "$REPRODUCE_TOML" || true)"
ac_assert_eq "$formula_timeout" "1" \
  "formulas/reproduce.toml must set timeout_minutes = 60 (got $formula_timeout)"

ac_log "AC 2: entrypoint has no Claude CLI invocation or config mount"
claude_hits="$(grep -nE 'claude -p|command -v claude|--mcp-server|CLAUDE_CONFIG_DIR|/usr/local/bin/claude|Claude' "$ENTRYPOINT" || true)"
[ -z "$claude_hits" ] \
  || ac_fail "entrypoint-reproduce.sh must not name the Claude CLI (got: ${claude_hits})"

ac_log "AC 3: both sessions call sidecar_agent_run"
# shellcheck disable=SC2016  # literal $CLAUDE_PROMPT, matching the issue's grep -cF
run_count="$(grep -cF 'sidecar_agent_run "$CLAUDE_PROMPT"' "$ENTRYPOINT" || true)"
ac_assert_eq "$run_count" "2" \
  "sidecar_agent_run must be called twice (got $run_count)"

ac_log "AC 4: sidecar-agent.sh is sourced once"
# shellcheck disable=SC2016  # literal ${DISINTO_DIR}, matching the issue's grep -cF
source_count="$(grep -cF 'source "${DISINTO_DIR}/docker/reproduce/sidecar-agent.sh"' "$ENTRYPOINT" || true)"
ac_assert_eq "$source_count" "1" \
  "sidecar-agent.sh must be sourced once (got $source_count)"

ac_log "AC 5: reproduce and triage formulas do not mention claude"
formula_hits="$(grep -n 'claude' "$REPRODUCE_TOML" "$TRIAGE_TOML" || true)"
[ -z "$formula_hits" ] \
  || ac_fail "formulas/reproduce.toml and formulas/triage.toml must not mention claude (got: ${formula_hits})"

ac_log "AC 6: entrypoint parses"
bash -n "$ENTRYPOINT" \
  || ac_fail "bash -n docker/reproduce/entrypoint-reproduce.sh failed"

ac_pass
