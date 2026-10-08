#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1951.sh — healer runs as its own host-side job
#
# Issue #1951: bin/healer.sh must run from nomad/jobs/healer.hcl, a raw_exec
# service job, not a task inside the edge job. This test greps the criteria.
# It does not submit a job or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1951.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/nomad/jobs/healer.hcl"
EDGE="$REPO_ROOT/nomad/jobs/edge.hcl"
DOC="$REPO_ROOT/nomad/AGENTS.md"
ac_assert_file "$SPEC" "nomad/jobs/healer.hcl must exist"
ac_assert_file "$EDGE" "nomad/jobs/edge.hcl must exist"
ac_assert_file "$DOC" "nomad/AGENTS.md must exist"

ac_log "checking job \"healer\" is defined once, and not inside edge.hcl"
job_count="$(grep -c 'job "healer"' "$SPEC" || true)"
ac_assert_eq "$job_count" "1" "grep -c 'job \"healer\"' must print 1 (got ${job_count})"
if grep -q 'job "healer"' "$EDGE" || grep -q '/opt/disinto/bin/healer.sh' "$EDGE"; then
  ac_fail "nomad/jobs/edge.hcl must not gain a healer job or task"
fi

ac_log "checking raw_exec command and env"
grep -q 'driver = "raw_exec"' "$SPEC" \
  || ac_fail "jobspec must set driver = \"raw_exec\""
grep -q 'command = "/opt/disinto/bin/healer.sh"' "$SPEC" \
  || ac_fail "jobspec must set command = \"/opt/disinto/bin/healer.sh\""
grep -q 'type = "service"' "$SPEC" \
  || ac_fail "jobspec must be type = \"service\""
grep -q 'count = 1' "$SPEC" \
  || ac_fail "jobspec must set count = 1"
grep -q 'NOMAD_ADDR = "http://localhost:4646"' "$SPEC" \
  || ac_fail "jobspec must set NOMAD_ADDR = \"http://localhost:4646\""
grep -q 'HEALER_STATE_DIR = "/srv/disinto/healer"' "$SPEC" \
  || ac_fail "jobspec must set HEALER_STATE_DIR = \"/srv/disinto/healer\""
grep -q 'TAPE_DIR = "/srv/disinto/tape"' "$SPEC" \
  || ac_fail "jobspec must set TAPE_DIR = \"/srv/disinto/tape\""
grep -q 'FACTORY_ROOT = "/opt/disinto"' "$SPEC" \
  || ac_fail "jobspec must set FACTORY_ROOT = \"/opt/disinto\""
grep -q 'attempts = 10' "$SPEC" \
  || ac_fail "restart attempts must be 10"
grep -q 'interval = "30m"' "$SPEC" \
  || ac_fail "restart interval must be \"30m\""
grep -q 'delay = "15s"' "$SPEC" \
  || ac_fail "restart delay must be \"15s\""
grep -q 'mode = "delay"' "$SPEC" \
  || ac_fail "restart mode must be \"delay\""
grep -q 'cpu = 50' "$SPEC" \
  || ac_fail "cpu must be 50"
grep -q 'memory = 128' "$SPEC" \
  || ac_fail "memory must be 128"
if grep -q 'vault {' "$SPEC"; then
  ac_fail "no vault block yet (#1954 adds the Telegram secret)"
fi

ac_log "checking the jobs table row"
row="| \`nomad/jobs/healer.hcl\` | deployed by hand (\`nomad job run\`) | runs \`bin/healer.sh\` on the host: restarts allocations to heal faults; the only job that does"
grep -qF -- "$row" "$DOC" \
  || ac_fail "nomad/AGENTS.md jobs table must name healer.hcl, deployed by hand, as the only job that restarts allocations"

echo PASS
