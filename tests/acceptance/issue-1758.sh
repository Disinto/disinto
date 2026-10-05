#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1758.sh
#
# Issue #1758: the dispatcher gives runners and sidecars no Claude credentials.
#
# _launch_runner_docker and _dispatch_sidecar_docker must not pass
# ANTHROPIC_API_KEY or bind-mount the claude binary, the shared Claude
# session, or ~/.claude.json. This deployment runs no Anthropic models.
#
# Acceptance (read-only; grep and bash -n):
#   * grep -n -E 'ANTHROPIC_API_KEY|/usr/local/bin/claude|claude-shared|CLAUDE_CONFIG_DIR|\.claude\.json'
#     docker/edge/dispatcher.sh prints nothing
#   * bash -n docker/edge/dispatcher.sh succeeds
#   * this test exits 0 and calls ac_pass
#
# Run via: tools/run-acceptance.sh 1758
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"

# grep exits 1 when there is no match; the script is set -e, so tolerate that.
matches="$(grep -n -E 'ANTHROPIC_API_KEY|/usr/local/bin/claude|claude-shared|CLAUDE_CONFIG_DIR|\.claude\.json' "$DISPATCHER" || true)"
[ -z "$matches" ] \
  || ac_fail "dispatcher.sh must not hand runners or sidecars Claude credentials (got: ${matches})"

bash -n "$DISPATCHER" \
  || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass
