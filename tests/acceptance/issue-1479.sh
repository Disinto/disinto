#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1479.sh
#
# Issue #1479: chore(agents): drop predictor from the default role list.
#
# The predictor (an LLM exploration controller, §11) must not run by default,
# but it must remain *available*: an operator who sets AGENT_ROLES explicitly
# can still start it. The two default role lists — the entrypoint default env
# AGENT_ROLES and the combined Nomad jobspec env — must no longer contain
# "predictor". The entrypoint's predictor start block must remain, still gated
# on AGENT_ROLES, and predictor/predictor-run.sh must still exist.
#
# Acceptance (read-only — no live services, no nomad-stop, no agents started;
# the defaults are grepped from the repo files):
#   1. entrypoint.sh default AGENT_ROLES contains no "predictor"
#   2. nomad/jobs/agents.hcl AGENT_ROLES contains no "predictor"
#   3. entrypoint.sh predictor start block is still gated on AGENT_ROLES
#   4. predictor/predictor-run.sh still exists
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

ENTRYPOINT="$REPO_ROOT/docker/agents/entrypoint.sh"
JOBHCL="$REPO_ROOT/nomad/jobs/agents.hcl"
PREDICTOR_RUN="$REPO_ROOT/predictor/predictor-run.sh"

# ── 1. entrypoint.sh default AGENT_ROLES has no "predictor" ─────────────────
ac_assert_file "$ENTRYPOINT" "docker/agents/entrypoint.sh must exist"
if grep -F 'AGENT_ROLES:' "$ENTRYPOINT" | grep -q 'predictor'; then
  ac_fail "entrypoint.sh default AGENT_ROLES still contains 'predictor'"
fi
# The default string must be the expected six-role list (no predictor).
if ! grep -qF 'review,dev,gardener,architect,planner,supervisor' "$ENTRYPOINT"; then
  ac_fail "entrypoint.sh default AGENT_ROLES is not the expected six-role list"
fi
ac_log "entrypoint.sh default AGENT_ROLES has no predictor"

# ── 2. nomad/jobs/agents.hcl AGENT_ROLES has no "predictor" ─────────────────
ac_assert_file "$JOBHCL" "nomad/jobs/agents.hcl must exist"
if grep -F 'AGENT_ROLES' "$JOBHCL" | grep -q 'predictor'; then
  ac_fail "nomad/jobs/agents.hcl AGENT_ROLES still contains 'predictor'"
fi
# The combined job's default is the five-role llama list (supervisor is a
# separate standalone opus job; predictor is dropped).
if ! grep -qF 'review,dev,gardener,architect,planner' "$JOBHCL"; then
  ac_fail "nomad/jobs/agents.hcl AGENT_ROLES is not the expected five-role list"
fi
ac_log "nomad/jobs/agents.hcl AGENT_ROLES has no predictor"

# ── 3. predictor start block remains, gated on AGENT_ROLES ───────────────────
# The gate line is:  if [[ ",AGENT_ROLES," == *",predictor,"* ]]; then
if ! grep -qF 'AGENT_ROLES},"' "$ENTRYPOINT" \
   || ! grep -qF 'predictor,"*' "$ENTRYPOINT"; then
  ac_fail "entrypoint.sh predictor start block must be gated on AGENT_ROLES"
fi
# It must still reference the predictor-run.sh invocation (operator can run it).
if ! grep -qF 'predictor/predictor-run.sh' "$ENTRYPOINT"; then
  ac_fail "entrypoint.sh predictor start block no longer references predictor-run.sh"
fi
ac_log "entrypoint.sh predictor start block remains gated on AGENT_ROLES"

# ── 4. predictor/predictor-run.sh still exists ──────────────────────────────
ac_assert_file "$PREDICTOR_RUN" "predictor/predictor-run.sh must still exist"
ac_log "predictor/predictor-run.sh still exists"

echo PASS
