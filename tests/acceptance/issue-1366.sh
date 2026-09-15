#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1366.sh — gardener-qwen OPS_REPO_ROOT + ops-repo mount
#
# Issue #1366: PROJECT_TOML is set, so env.sh requires OPS_REPO_ROOT and
# PRIMARY_BRANCH. The ops-repo host volume must not cover the writable
# clone at /home/agent/repos/disinto-ops (oak/tick.sh mkdir). Match
# agents-dev-qwen.hcl: mount at /home/agent/repos/_factory/disinto-ops.
#
# Read-only checks against the checkout.
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

GQ="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
ac_assert_file "$GQ" "agents-gardener-qwen.hcl must exist"

ac_log "checking OPS_REPO_ROOT"
grep -Eq '^[[:space:]]*OPS_REPO_ROOT[[:space:]]*=[[:space:]]*"/home/agent/repos/disinto-ops"' "$GQ" \
  || ac_fail "agents-gardener-qwen.hcl must set OPS_REPO_ROOT to /home/agent/repos/disinto-ops"

ac_log "checking PRIMARY_BRANCH"
grep -Eq '^[[:space:]]*PRIMARY_BRANCH[[:space:]]*=[[:space:]]*"main"' "$GQ" \
  || ac_fail "agents-gardener-qwen.hcl must set PRIMARY_BRANCH = \"main\""

ac_log "checking ops-repo mount destination"
grep -Fq 'destination = "/home/agent/repos/_factory/disinto-ops"' "$GQ" \
  || ac_fail "ops-repo volume_mount must land at /home/agent/repos/_factory/disinto-ops"

ac_log "checking ops-repo is not covering the writable clone"
if grep -Fq 'destination = "/home/agent/repos/disinto-ops"' "$GQ"; then
  ac_fail "ops-repo must not mount on /home/agent/repos/disinto-ops"
fi

echo PASS
