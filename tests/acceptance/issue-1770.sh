#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1770.sh — edge job drops chat and voice secrets
#
# Issue #1770: after #1768 and #1769, nomad/jobs/edge.hcl must no longer
# render chat and voice secrets or set their env. Chat-only volume mounts
# (threads-state, snapshot-state, inbox-state) are gone. The forge PAT
# template, FACTORY_FORGE_PAT_FILE, and the snapshot task stay.
#
# #1846 removed the claude-shared OAuth probe mount — the sidecars now run
# dsh against DSH_BASE_URL and never `claude -p`. The snapshot task is
# raw_exec and still sets INBOX_ROOT to the host sentinel path; a whole-file
# ban on "inbox-state" would lock in that break.
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

ac_log "checking edge.hcl has no chat/voice secrets or env"
if grep -nE 'gemini-api-key|chat-oauth|nomad-token|CHAT_|VOICE_|GEMINI|EDGE_TUNNEL_FQDN|EDGE_ROUTING_MODE|FORGE_PUBLIC_URL|CLAUDE_CONFIG_DIR|threads-state' "$SPEC"; then
  ac_fail "edge.hcl still references chat/voice secrets, env, or the threads-state mount"
fi

ac_log "checking the snapshot task still writes inbox sentinels on the host path"
grep -Fq 'INBOX_ROOT    = "/srv/disinto/inbox-state"' "$SPEC" \
  || ac_fail "snapshot task must keep INBOX_ROOT on the host sentinel path"

ac_log "checking forge PAT template, FACTORY_FORGE_PAT_FILE, and snapshot task remain"
grep -q 'secrets/forge-pat' "$SPEC" \
  || ac_fail "secrets/forge-pat template missing from edge.hcl"
grep -q 'FACTORY_FORGE_PAT_FILE' "$SPEC" \
  || ac_fail "FACTORY_FORGE_PAT_FILE missing from edge.hcl"
grep -q 'task "snapshot"' "$SPEC" \
  || ac_fail "task \"snapshot\" missing from edge.hcl"

echo PASS
