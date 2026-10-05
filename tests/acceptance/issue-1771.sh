#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1771.sh — the edge image drops the chat/voice surface
#
# Issue #1771 (step 4 of 4): docker/edge/Dockerfile must no longer bake in the
# chat/voice surface — chat-server.py + UI, chat-skills/templates, disinto-mcp,
# the voice bridge + UI, or the voice venv (google-genai / websockets).
#
# The Claude Code CLI install is KEPT, not dropped: it is a shared runtime
# dependency of the live reproduce/triage/verify sidecars, which run on
# docker/reproduce (no CLI installed) and mount /usr/local/bin/claude (ro)
# from this image; entrypoint-reproduce.sh:126 FATALs without it and
# dispatcher.sh:1217 skips the mount when it is absent. Dropping the CLI here
# would break the live bug-report lifecycle.
#
# Read-only: greps docker/edge/Dockerfile. The image build itself is verified
# in CI by .woodpecker/build-edge.yml after merge.
#
# Acceptance: `bash tests/acceptance/issue-1771.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/docker/edge/Dockerfile"
ac_assert_file "$SPEC" "docker/edge/Dockerfile must exist"

ac_log "checking the chat/voice surface is gone from the image"
if grep -nE 'chat-server|chat/ui|chat-skills|chat-settings|chat-mcp|disinto-mcp|voice-bridge|voice/ui|voice-venv|google-genai|websockets' "$SPEC"; then
  ac_fail "docker/edge/Dockerfile still bakes in the chat/voice surface"
fi

ac_log "checking the CLI remains for the reproduce/triage/verify sidecars"
grep -q 'claude-code' "$SPEC" \
  || ac_fail "claude-code missing from docker/edge/Dockerfile — the reproduce/triage/verify sidecars FATAL without it (dispatcher.sh:1217, entrypoint-reproduce.sh:126)"

ac_log "checking engagement-server.py, nomad, and entrypoint-edge.sh remain"
grep -q 'engagement-server.py' "$SPEC" \
  || ac_fail "engagement-server.py missing from docker/edge/Dockerfile"
grep -q 'nomad' "$SPEC" \
  || ac_fail "nomad missing from docker/edge/Dockerfile"
grep -q 'entrypoint-edge.sh' "$SPEC" \
  || ac_fail "entrypoint-edge.sh missing from docker/edge/Dockerfile"

echo PASS
