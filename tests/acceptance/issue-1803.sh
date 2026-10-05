#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1803.sh
#
# Issue #1803: the dispatcher gives the vault runner DSH_BASE_URL, not the
# Claude session. After #1776 the vault runner runs .toml formulas with dsh
# (agent_run) and needs DSH_BASE_URL; it runs no Claude and gets no OAuth
# session. This change:
#   * removes the claude-shared / CLAUDE_CONFIG_DIR / .claude.json mounts
#     from _launch_runner_docker (docker/edge/dispatcher.sh);
#   * passes DSH_BASE_URL=${DSH_BASE_URL} to the runner when set;
#   * sets DSH_BASE_URL on the caddy task env block in nomad/jobs/edge.hcl
#     (same value as nomad/jobs/agents-dev-qwen.hcl).
#
# Read-only: sed/grep over repo files only. No network, no sockets, no job
# submit.
#
# Acceptance (the three issue criteria):
#   * _launch_runner_docker has no claude-shared / CLAUDE_SHARED_DIR /
#     CLAUDE_CONFIG_DIR / .claude.json references
#   * _launch_runner_docker passes DSH_BASE_URL=${DSH_BASE_URL} exactly once
#   * nomad/jobs/edge.hcl sets DSH_BASE_URL = "http://10.10.10.1:8088/v1"
#     exactly once
#
# Run via: tools/run-acceptance.sh 1803
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash sed grep

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
SPEC="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"
ac_assert_file "$SPEC" "nomad/jobs/edge.hcl must exist"

# Extract the runner launcher (column-0 header to column-0 closing brace),
# mirroring the issue criteria's sed range.
FN_RUNNER="$(ac_extract_fn _launch_runner_docker "$DISPATCHER")"
[ -n "$FN_RUNNER" ] \
  || ac_fail "could not extract _launch_runner_docker from docker/edge/dispatcher.sh"

# Comments may name the values; the mounts/passthroughs in the body must be
# gone (or present exactly as expected). grep exits 1 when there is no match.

ac_log "CR1: _launch_runner_docker has no claude-session references"
cr1="$(grep -nE 'claude-shared|CLAUDE_SHARED_DIR|CLAUDE_CONFIG_DIR|\.claude\.json' <<<"$FN_RUNNER" || true)"
[ -z "$cr1" ] \
  || ac_fail "_launch_runner_docker must not reference claude-shared / CLAUDE_CONFIG_DIR / .claude.json (got: ${cr1})"

ac_log "CR2: _launch_runner_docker passes DSH_BASE_URL once"
cr2="$(grep -cF 'DSH_BASE_URL=${DSH_BASE_URL}' <<<"$FN_RUNNER" || true)"
[ "$cr2" = "1" ] \
  || ac_fail "_launch_runner_docker must pass DSH_BASE_URL=${DSH_BASE_URL} exactly once (got: $cr2)"

ac_log "CR3: edge.hcl sets DSH_BASE_URL on the caddy task once"
cr3="$(grep -cE '^ *DSH_BASE_URL *= *"http://10\.10\.10\.1:8088/v1"' "$SPEC" || true)"
[ "$cr3" = "1" ] \
  || ac_fail "nomad/jobs/edge.hcl must set DSH_BASE_URL exactly once (got: $cr3)"

bash -n "$DISPATCHER" \
  || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass
