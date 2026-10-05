#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1770.sh — edge job drops chat and voice secrets
#
# Issue #1770: after #1768 and #1769, nomad/jobs/edge.hcl must no longer
# render chat and voice secrets, set their env, or mount chat-only volumes.
# The forge PAT template, FACTORY_FORGE_PAT_FILE, and the snapshot task stay.
#
# Read-only: greps nomad/jobs/edge.hcl. Does not submit a job or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1770.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$SPEC" "nomad/jobs/edge.hcl must exist"

ac_log "checking edge.hcl has no chat/voice secrets, env, or mounts"
if grep -nE 'gemini-api-key|chat-oauth|nomad-token|CHAT_|VOICE_|GEMINI|EDGE_TUNNEL_FQDN|EDGE_ROUTING_MODE|FORGE_PUBLIC_URL|claude-shared|CLAUDE_CONFIG_DIR|threads-state|inbox-state' "$SPEC"; then
  ac_fail "edge.hcl still references chat/voice secrets, env, or mounts"
fi

ac_log "checking forge PAT template, FACTORY_FORGE_PAT_FILE, and snapshot task remain"
grep -q 'secrets/forge-pat' "$SPEC" \
  || ac_fail "secrets/forge-pat template missing from edge.hcl"
grep -q 'FACTORY_FORGE_PAT_FILE' "$SPEC" \
  || ac_fail "FACTORY_FORGE_PAT_FILE missing from edge.hcl"
grep -q 'task "snapshot"' "$SPEC" \
  || ac_fail "task \"snapshot\" missing from edge.hcl"

echo PASS
