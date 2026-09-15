#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1357.sh — gardener-qwen jobspec runs the local-Qwen
# dsh harness like dev-qwen
#
# Issue #1357 (Oak sprint 2): agents-gardener-qwen.hcl must hire/start the
# gardener on the local-Qwen dsh path (AGENT_HARNESS=dsh + DSH_* env), the
# way agents-dev-qwen.hcl does — not the Claude CLI against Anthropic cloud.
# The stock gardener job also depends on the agent-data-gardener host volume
# (client.hcl) being created by cluster-up.sh (HOST_VOLUME_DIRS), so the
# two stay in lockstep.
#
# Read-only checks against the checkout:
#   1. agents-gardener-qwen.hcl sets AGENT_HARNESS = "dsh"
#   2. agents-gardener-qwen.hcl sets DSH_MODEL
#   3. DSH_BASE_URL in the gardener job is the same host:port as in the
#      dev-qwen job (the local llama-server, not Anthropic)
#   4. AGENT_ROLES is still "gardener" (role pinning survives)
#   5. cluster-up.sh HOST_VOLUME_DIRS includes /srv/disinto/agent-data-gardener
#   6. nomad/client.hcl declares host_volume "agent-data-gardener"
#   7. bash -n — cluster-up.sh stays syntactically valid
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_require_cmd grep

GQ="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
DQ="$REPO_ROOT/nomad/jobs/agents-dev-qwen.hcl"
CU="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
CH="$REPO_ROOT/nomad/client.hcl"

ac_assert_file "$GQ" "agents-gardener-qwen.hcl must exist in the checkout"
ac_assert_file "$DQ" "agents-dev-qwen.hcl must exist in the checkout"
ac_assert_file "$CU" "lib/init/nomad/cluster-up.sh must exist in the checkout"
ac_assert_file "$CH" "nomad/client.hcl must exist in the checkout"

# 1. The gardener job switches to the dsh harness.
ac_log "checking AGENT_HARNESS=dsh"
grep -Eq '^[[:space:]]*AGENT_HARNESS[[:space:]]*=[[:space:]]*"dsh"' "$GQ" \
  || ac_fail "agents-gardener-qwen.hcl must set AGENT_HARNESS = \"dsh\""

# 2. DSH_MODEL is set (the local Qwen, not Anthropic cloud).
ac_log "checking DSH_MODEL"
grep -Eq '^[[:space:]]*DSH_MODEL[[:space:]]*=[[:space:]]*"[^"]+"' "$GQ" \
  || ac_fail "agents-gardener-qwen.hcl must set DSH_MODEL"

# 3. DSH_BASE_URL targets the same host:port as dev-qwen — the local
#    llama-server. Compared host:port (scheme + host + port), ignoring the
#    path suffix, so both jobs can address it consistently.
ac_log "checking DSH_BASE_URL host:port matches dev-qwen"
hostport_of() {
  sed -nE 's/^[[:space:]]*DSH_BASE_URL[[:space:]]*=[[:space:]]*"https?:\/\/([^/]+).*/\1/p' "$1"
}
dev_hostport="$(hostport_of "$DQ")"
gard_hostport="$(hostport_of "$GQ")"
[ -n "$gard_hostport" ] \
  || ac_fail "agents-gardener-qwen.hcl must set DSH_BASE_URL"
[ -n "$dev_hostport" ] \
  || ac_fail "agents-dev-qwen.hcl must set DSH_BASE_URL"
ac_assert_eq "$gard_hostport" "$dev_hostport" \
  "gardener-qwen DSH_BASE_URL host:port ($gard_hostport) != dev-qwen ($dev_hostport)"

# 4. The role pinning survives the migration.
ac_log "checking AGENT_ROLES=gardener"
grep -Eq '^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*"gardener"' "$GQ" \
  || ac_fail "agents-gardener-qwen.hcl must keep AGENT_ROLES = \"gardener\""

# 5. cluster-up.sh creates the gardener state directory on fresh clusters —
#    extract the HOST_VOLUME_DIRS array body and check it.
ac_log "checking HOST_VOLUME_DIRS includes agent-data-gardener"
vols="$(sed -n '/^HOST_VOLUME_DIRS=(/,/^)/p' "$CU")"
printf '%s\n' "$vols" | grep -q '/srv/disinto/agent-data-gardener' \
  || ac_fail "cluster-up.sh HOST_VOLUME_DIRS must include /srv/disinto/agent-data-gardener"

# 6. The client config still declares the matching host_volume (paired-write
#    contract, nomad/AGENTS.md).
ac_log "checking client.hcl declares host_volume agent-data-gardener"
grep -Eq 'host_volume[[:space:]]+"agent-data-gardener"' "$CH" \
  || ac_fail "nomad/client.hcl must declare host_volume \"agent-data-gardener\""

# 7. cluster-up.sh stays syntactically valid.
ac_log "checking bash -n cluster-up.sh"
bash -n "$CU" 2>/dev/null \
  || ac_fail "lib/init/nomad/cluster-up.sh fails bash -n"

echo PASS
