#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1840.sh
#
# Issue #1840: the reproduce/triage/verify sidecar image carries dsh,
# Playwright MCP and the factory code, not the Claude CLI or Debian's Node.
#
# Read-only. Building the image needs a Docker daemon; #1839 does that
# after merge.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep sed

REPRO="$REPO_ROOT/docker/reproduce/Dockerfile"
AGENTS="$REPO_ROOT/docker/agents/Dockerfile"

ac_assert_file "$REPRO" "docker/reproduce/Dockerfile must exist"
ac_assert_file "$AGENTS" "docker/agents/Dockerfile must exist"

ac_log "checking the sidecar Dockerfile does not name claude"
claude_hits="$(grep -n 'claude' "$REPRO" || true)"
[ -z "$claude_hits" ] || ac_fail "docker/reproduce/Dockerfile mentions claude: ${claude_hits}"

ac_log "checking the apt install does not pull distro nodejs or npm"
distro_node="$(sed -n '/apt-get install/,/rm -rf/p' "$REPRO" | grep -nwE 'nodejs|npm' || true)"
[ -z "$distro_node" ] || ac_fail "apt-get install still names nodejs or npm: ${distro_node}"

ac_log "checking the dsh pin matches docker/agents/Dockerfile"
repro_dsh="$(grep -o '@deepseek-ai/dsh@[^ ]*' "$REPRO")"
agents_dsh="$(grep -o '@deepseek-ai/dsh@[^ ]*' "$AGENTS")"
ac_assert_eq "$repro_dsh" "$agents_dsh" \
  "dsh pin '$repro_dsh' does not match agents pin '$agents_dsh'"

ac_log "checking the Node tarball pin matches docker/agents/Dockerfile"
repro_node="$(grep -o 'node-v[0-9.]*-linux-x64' "$REPRO" | head -1)"
agents_node="$(grep -o 'node-v[0-9.]*-linux-x64' "$AGENTS" | head -1)"
ac_assert_eq "$repro_node" "$agents_node" \
  "Node pin '$repro_node' does not match agents pin '$agents_node'"

ac_log "checking Playwright MCP, factory COPY and dsh settings each appear once"
for needle in '@playwright/mcp@0.0.80' 'COPY . /home/agent/disinto' '/opt/dsh/settings-llamacpp.yaml'; do
  count="$(grep -c "$needle" "$REPRO" || true)"
  ac_assert_eq "$count" "1" "expected '$needle' once in docker/reproduce/Dockerfile, found $count"
done

ac_pass
