#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1788.sh — the chat/voice control surface is fully
# deleted from the repo (wave 2 of chat removal)
#
# Issue #1788: after the running edge lost chat/voice (#1768-#1771), the dead
# code is still tracked. This PR deletes it: the chat server + UI
# (docker/chat/), its skills (docker/edge/chat-skills/), the Claude settings /
# MCP wiring (docker/edge/chat-settings.json, chat-mcp.json, disinto-mcp), the
# persona (SOUL.md), the design doc (docs/CHAT-CONTROL-SURFACE.md), the
# inbox-ack helper that only the chat skills call (bin/inbox-ack.sh), and one
# chat-skill regression test (tests/smoke-check-inbox-factory-root.sh). All of
# these must be untracked after this change.
#
# Read-only: only `git ls-files` and `grep` against the repo. No state is
# mutated; per the runner convention, reviewer-agent rejects mutating tests.
#
# Checks:
#   1. The deleted chat paths are no longer tracked (`git ls-files` empty).
#   2. No `chat-skills` reference remains in docs/AGENTS.md, INFRASTRUCTURE.md,
#      or tests/acceptance/issue-861.sh.
#
# Acceptance: `bash tests/acceptance/issue-1788.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd git grep

# Files/dirs that must no longer be tracked after chat removal (#1788).
DELETED=(
  docker/chat
  docker/edge/chat-skills
  docker/edge/chat-settings.json
  docker/edge/chat-mcp.json
  docker/edge/disinto-mcp
  SOUL.md
  docs/CHAT-CONTROL-SURFACE.md
  bin/inbox-ack.sh
  tests/smoke-check-inbox-factory-root.sh
)

# ── 1. The deleted chat paths must be untracked ──────────────────────────────

ac_log "checking the chat files are no longer tracked"
# git ls-files exits 0 and prints nothing when a path (or everything under it)
# is untracked; any non-empty output means the path or a tracked descendant
# (e.g. docker/chat/server.py) still remains.
out="$(git ls-files "${DELETED[@]}" || true)"
if [ -n "$out" ]; then
  ac_fail "still tracked after #1788: $out"
fi

# ── 2. No chat-skills reference remains in the docs or forge-collector test ─

ac_log "checking no chat-skills reference remains"
if grep -n chat-skills \
  tests/acceptance/issue-861.sh docs/AGENTS.md INFRASTRUCTURE.md; then
  ac_fail "chat-skills still referenced in docs/AGENTS.md, INFRASTRUCTURE.md, or issue-861.sh"
fi

echo PASS
