#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1845.sh — the edge image drops the Claude CLI,
# nodejs and npm
#
# Issue #1845: reproduce/triage/verify sidecars run dsh against the local
# model and no longer mount the Claude CLI. docker/edge/Dockerfile must not
# install nodejs, npm, or @anthropic-ai/claude-code. engagement-server.py
# stays. This test only reads files.
#
# Acceptance:
#   1. grep -niE 'claude|nodejs|npm' docker/edge/Dockerfile prints nothing.
#   2. grep -c 'engagement-server.py' docker/edge/Dockerfile is at least 1.
#
# Run via: tools/run-acceptance.sh 1845
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/docker/edge/Dockerfile"
ac_assert_file "$SPEC" "docker/edge/Dockerfile must exist"

ac_log "AC 1: edge Dockerfile names no claude, nodejs, or npm"
hits="$(grep -niE 'claude|nodejs|npm' "$SPEC" || true)"
[ -z "$hits" ] \
  || ac_fail "docker/edge/Dockerfile still names claude, nodejs, or npm: ${hits}"

ac_log "AC 2: engagement-server.py remains in the edge Dockerfile"
count="$(grep -c 'engagement-server.py' "$SPEC" || true)"
if [ "$count" -lt 1 ]; then
  ac_fail "engagement-server.py missing from docker/edge/Dockerfile (count=${count})"
fi

ac_pass
