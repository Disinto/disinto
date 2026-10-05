#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1769.sh — the edge no longer starts chat or voice
#
# Issue #1769: the edge entrypoint must no longer prepare/start the chat
# server or the voice bridge. The dispatcher, engagement server, Caddy run,
# and the wait -n/exit 1 tail must remain. This is step 2 of 4 (step 1, #1768,
# removed the Caddy routes); #1770 drops the job secrets/env/mounts and #1771
# drops the baked-in chat/voice files.
#
# Read-only: greps docker/edge/entrypoint-edge.sh and runs `bash -n`. Does not
# build an image or start a process.
#
# Acceptance: `bash tests/acceptance/issue-1769.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep bash

SPEC="$REPO_ROOT/docker/edge/entrypoint-edge.sh"
ac_assert_file "$SPEC" "docker/edge/entrypoint-edge.sh must exist"

ac_log "checking entrypoint-edge.sh no longer names chat-server.py, voice-bridge.py, _chat_, GEMINI_API_KEY, or VOICE_PORT"
if grep -nE 'chat-server\.py|voice-bridge\.py|_chat_|GEMINI_API_KEY|VOICE_PORT' "$SPEC"; then
  ac_fail "entrypoint-edge.sh still references chat/voice startup"
fi

ac_log "checking dispatcher start remains"
grep -q 'bash /opt/disinto/docker/edge/dispatcher.sh &' "$SPEC" \
  || ac_fail "dispatcher start missing from entrypoint-edge.sh"

ac_log "checking engagement server, caddy run, and wait -n remain"
grep -q 'engagement-server.py' "$SPEC" \
  || ac_fail "engagement-server.py start missing from entrypoint-edge.sh"
grep -q 'caddy run' "$SPEC" \
  || ac_fail "caddy run missing from entrypoint-edge.sh"
grep -q 'wait -n' "$SPEC" \
  || ac_fail "wait -n missing from entrypoint-edge.sh"

ac_log "checking entrypoint-edge.sh parses (bash -n)"
bash -n "$SPEC" \
  || ac_fail "entrypoint-edge.sh fails bash -n syntax check"

echo PASS
