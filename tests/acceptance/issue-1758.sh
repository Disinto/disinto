#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1758.sh
#
# Issue #1758: the dispatcher must not hand runners or sidecars an
# Anthropic API key. The edge job authenticates Claude via the shared
# OAuth session, and explicitly does not set ANTHROPIC_API_KEY.
#
# The OAuth mounts stay. entrypoint-reproduce.sh fatals without the host
# CLI and runs `claude -p`; entrypoint-runner.sh execs `claude -p` for
# every .toml formula and does not read AGENT_HARNESS. A whole-file ban
# on claude-shared / CLAUDE_CONFIG_DIR / .claude.json / the CLI mount
# would lock in that break (#1776). The agents image already contains
# the CLI, so the runner does not bind-mount the binary.
#
# Acceptance (read-only; grep and bash -n):
#   * no ANTHROPIC_API_KEY= passthrough remains in docker/edge/dispatcher.sh
#   * _launch_runner_docker still mounts claude-shared, sets
#     CLAUDE_CONFIG_DIR, and mounts .claude.json; it does not mount
#     /usr/local/bin/claude
#   * _dispatch_sidecar_docker still mounts the CLI, claude-shared,
#     CLAUDE_CONFIG_DIR, and .claude.json
#   * bash -n docker/edge/dispatcher.sh succeeds
#
# Run via: tools/run-acceptance.sh 1758
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"

# Comments may name the variable. The passthrough (`ANTHROPIC_API_KEY=`) must
# be gone. grep exits 1 when there is no match; the script is set -e.
api_key="$(grep -n -E 'ANTHROPIC_API_KEY=' "$DISPATCHER" || true)"
[ -z "$api_key" ] \
  || ac_fail "dispatcher.sh must not pass ANTHROPIC_API_KEY (got: ${api_key})"

FN_RUNNER="$(ac_extract_fn _launch_runner_docker "$DISPATCHER")"
[ -n "$FN_RUNNER" ] \
  || ac_fail "could not extract _launch_runner_docker from docker/edge/dispatcher.sh"
grep -q 'claude-shared' <<<"$FN_RUNNER" \
  || ac_fail "_launch_runner_docker must still mount claude-shared (OAuth session)"
grep -q 'CLAUDE_CONFIG_DIR' <<<"$FN_RUNNER" \
  || ac_fail "_launch_runner_docker must still set CLAUDE_CONFIG_DIR"
grep -qF '.claude.json' <<<"$FN_RUNNER" \
  || ac_fail "_launch_runner_docker must still mount .claude.json"
if grep -qF '/usr/local/bin/claude' <<<"$FN_RUNNER"; then
  ac_fail "_launch_runner_docker must not bind-mount /usr/local/bin/claude; the agents image has the CLI"
fi

FN_SIDECAR="$(ac_extract_fn _dispatch_sidecar_docker "$DISPATCHER")"
[ -n "$FN_SIDECAR" ] \
  || ac_fail "could not extract _dispatch_sidecar_docker from docker/edge/dispatcher.sh"
grep -qF '/usr/local/bin/claude' <<<"$FN_SIDECAR" \
  || ac_fail "_dispatch_sidecar_docker must still mount /usr/local/bin/claude"
grep -q 'claude-shared' <<<"$FN_SIDECAR" \
  || ac_fail "_dispatch_sidecar_docker must still mount claude-shared"
grep -q 'CLAUDE_CONFIG_DIR' <<<"$FN_SIDECAR" \
  || ac_fail "_dispatch_sidecar_docker must still set CLAUDE_CONFIG_DIR"
grep -qF '.claude.json' <<<"$FN_SIDECAR" \
  || ac_fail "_dispatch_sidecar_docker must still mount .claude.json"

bash -n "$DISPATCHER" \
  || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass
