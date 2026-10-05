#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1779.sh — edge.hcl header names the live backend
#
# Issue #1779: the header comment of nomad/jobs/edge.hcl still claimed that
# docker-compose.yml is the factory's live stack ("Not the runtime yet").
# The production factory runs the Nomad+Vault backend (docs/updating-factory.md),
# and `disinto init --backend=nomad --with edge` deploys this job. An agent
# trusting the stale header might edit the compose stack instead of this file.
#
# This test is read-only: it greps nomad/jobs/edge.hcl. It does not submit a
# job or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1779.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$SPEC" "nomad/jobs/edge.hcl must exist"

ac_log "checking the stale docker-compose-is-live wording is gone"
if grep -nE 'Not the runtime yet|until cutover' "$SPEC"; then
  ac_fail "edge.hcl header still claims docker-compose.yml is the live stack"
fi

ac_log "checking the new live-edge header is present exactly once"
live_count="$(grep -c '^# This is the live edge' "$SPEC" || true)"
[ "$live_count" = "1" ] \
  || ac_fail "edge.hcl header must state it is the live edge exactly once (got: ${live_count})"

echo PASS
