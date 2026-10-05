#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1768.sh — Caddy no longer routes /chat and /voice
#
# Issue #1768: the edge Caddyfile must not expose /chat or /voice. The
# remaining routes (/forge, /staging, /api/engagement) stay. Chat and voice
# processes are a later step (#1769); this test only checks the jobspec.
#
# Read-only: greps nomad/jobs/edge.hcl. Does not submit a job or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1768.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$SPEC" "nomad/jobs/edge.hcl must exist"

ac_log "checking edge.hcl does not route /chat or /voice"
if grep -nE 'handle /(chat|voice)|CHAT_PORT|VOICE_PORT' "$SPEC"; then
  ac_fail "edge.hcl still routes /chat or /voice, or still names CHAT_PORT/VOICE_PORT"
fi

ac_log "checking /forge, /staging, and /api/engagement routes remain"
grep -q 'handle /forge/\*' "$SPEC" \
  || ac_fail "handle /forge/* missing from edge.hcl"
grep -q 'handle /staging/\*' "$SPEC" \
  || ac_fail "handle /staging/* missing from edge.hcl"
grep -q 'handle /api/engagement' "$SPEC" \
  || ac_fail "handle /api/engagement missing from edge.hcl"

echo PASS
