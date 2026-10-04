#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1682.sh
#
# Issue #1682: seed dsh settings when no agent harness is set.
#
# docker/agents/entrypoint.sh seeds $DSH_HOME/settings.yaml and runs the
# context-window migration only when AGENT_HARNESS is dsh. An unset variable
# used to mean claude, so a container without the variable ran dsh with no
# provider settings and failed with MISSING_CREDENTIAL. Unset now means dsh.
#
# Acceptance (no network; grep and bash -n):
#   * grep -c 'AGENT_HARNESS:-claude' docker/agents/entrypoint.sh prints 0
#   * grep -c 'AGENT_HARNESS:-dsh' docker/agents/entrypoint.sh prints 2
#   * bash -n docker/agents/entrypoint.sh succeeds
#   * this test exits 0 and calls ac_pass
#
# Run via: tools/run-acceptance.sh 1682
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

ENTRYPOINT="$REPO_ROOT/docker/agents/entrypoint.sh"
ac_assert_file "$ENTRYPOINT" "docker/agents/entrypoint.sh must exist"

# grep -c exits 1 when the count is 0; the script is set -e, so tolerate that.
claude_count="$(grep -c 'AGENT_HARNESS:-claude' "$ENTRYPOINT" || true)"
ac_assert_eq "$claude_count" "0" \
  "AGENT_HARNESS:-claude must not remain in docker/agents/entrypoint.sh (got $claude_count)"

dsh_count="$(grep -c 'AGENT_HARNESS:-dsh' "$ENTRYPOINT" || true)"
ac_assert_eq "$dsh_count" "2" \
  "AGENT_HARNESS:-dsh must appear twice in docker/agents/entrypoint.sh (got $dsh_count)"

bash -n "$ENTRYPOINT" \
  || ac_fail "bash -n docker/agents/entrypoint.sh failed"

ac_pass
