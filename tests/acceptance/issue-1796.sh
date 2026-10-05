#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1796.sh — compose generators and templates no longer
# carry chat or voice
#
# Issue #1796: generate_compose() and the Caddyfile generators drop the chat
# service, chat/voice edge env, and forward_auth routes. The tracked
# docker-compose.yml and .env.example drop the same variables. The
# generate_compose() row in lib/AGENTS.md no longer mentions chat.
#
# Read-only: grep and bash -n. No live box.
#
# Acceptance: `bash tests/acceptance/issue-1796.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep bash

ac_log "checking generators and templates do not mention chat, voice, forward_auth, or gemini"
if grep -niE 'chat|voice|forward_auth|gemini' \
  lib/generators.sh docker-compose.yml .env.example; then
  ac_fail "chat, voice, forward_auth, or gemini remains in the compose generators or templates"
fi

ac_log "checking the generate_compose() row in lib/AGENTS.md does not mention chat"
count="$(grep -F 'generate_compose()' lib/AGENTS.md | grep -ci chat || true)"
if [ "$count" != "0" ]; then
  ac_fail "generate_compose() row in lib/AGENTS.md still mentions chat (count=$count)"
fi

ac_log "checking lib/generators.sh parses (bash -n)"
bash -n lib/generators.sh || ac_fail "bash -n lib/generators.sh failed"

echo PASS
