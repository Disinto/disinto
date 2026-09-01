#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1173-agents-image-rebuild.sh
#
# Issue #1173: nothing rebuilds disinto/agents:local, so every Dockerfile
# fix merged and never shipped (the box only built the :local tag at install
# time).
#
# The fix adds a `rebuild-and-deploy-agents` step to .woodpecker/ci.yml that
# rebuilds disinto/agents:local from docker/agents/Dockerfile and redeploys
# the agent jobspecs — but ONLY on push to main touching docker/agents/**,
# because restarting the agent jobs kills in-flight sessions (#1164 re-queues
# interrupted issues, so the cost is acceptable for a rare path).
#
# This test is read-only: it parses .woodpecker/ci.yml and asserts that the
# step exists, is path-filtered to docker/agents/** on push to main, builds
# the exact :local tag the agent jobspecs reference, and takes the shared
# deploy lock. It builds nothing and deploys nothing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep sed sort

CI_YML="$REPO_ROOT/.woodpecker/ci.yml"
ac_assert_file "$CI_YML" ".woodpecker/ci.yml must exist"

# ── Extract the rebuild-and-deploy-agents step block (read-only) ────────────
# From its `- name:` line (2-space indent, like every step in ci.yml) up to
# the next step's `- name:` line or end of file.
STEP_BLOCK="$(awk '
  /^  - name: rebuild-and-deploy-agents/ { in_step = 1 }
  in_step && /^  - name:/ && $0 !~ /rebuild-and-deploy-agents/ { in_step = 0 }
  in_step { print }
' "$CI_YML")"

if [ -z "$STEP_BLOCK" ]; then
  ac_fail "no step named rebuild-and-deploy-agents in .woodpecker/ci.yml"
fi

# ── The step exists and runs only on push to main touching docker/agents/** ─
ac_log "checking the step is gated to push on main"
printf '%s\n' "$STEP_BLOCK" | grep -q 'event: push' \
  || ac_fail "rebuild-and-deploy-agents is not gated on event: push"
printf '%s\n' "$STEP_BLOCK" | grep -q 'branch: main' \
  || ac_fail "rebuild-and-deploy-agents is not gated on branch: main"

ac_log "checking the step is path-filtered to docker/agents/**"
printf '%s\n' "$STEP_BLOCK" | grep -q 'docker/agents/\*\*' \
  || ac_fail "rebuild-and-deploy-agents is not path-filtered to docker/agents/** (it must not run on every push)"

# ── It builds the exact :local tag the agent jobspecs reference ─────────────
ac_log "checking the step rebuilds the tag the agent jobspecs reference"

# Every agents*.hcl jobspec must reference one identical agents image tag...
JOBSPEC_TAGS="$(grep -hoE 'image[[:space:]]*=[[:space:]]*"[^"]+"' "$REPO_ROOT"/nomad/jobs/agents*.hcl \
  | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)"
if [ -z "$JOBSPEC_TAGS" ]; then
  ac_fail "no agent image reference found in nomad/jobs/agents*.hcl"
fi
if [ "$(printf '%s\n' "$JOBSPEC_TAGS" | wc -l)" -ne 1 ]; then
  ac_fail "agent jobspecs reference more than one image tag: $JOBSPEC_TAGS"
fi

# ...and the ci.yml step must docker-build exactly that tag...
BUILT_TAG="$(printf '%s\n' "$STEP_BLOCK" | grep -oE 'docker build -t [^ ]+' | awk '{print $4}')"
if [ -z "$BUILT_TAG" ]; then
  ac_fail "rebuild-and-deploy-agents does not run docker build"
fi
ac_assert_eq "$BUILT_TAG" "$JOBSPEC_TAGS" "ci.yml builds '$BUILT_TAG' but the agent jobspecs run '$JOBSPEC_TAGS'"

# ...from docker/agents/Dockerfile
printf '%s\n' "$STEP_BLOCK" | grep -q 'docker/agents/Dockerfile' \
  || ac_fail "rebuild-and-deploy-agents does not build from docker/agents/Dockerfile"

# ── The redeploy loop discovers jobspecs by glob, not a hardcoded list ──────
# A hardcoded jobspec list would silently stop redeploying a future
# nomad/jobs/agents-<x>.hcl (the same "merged but never ships" class #1173
# fixes), so the loop must derive its list from the agents* glob.
ac_log "checking the redeploy loop derives the jobspec list from the agents* glob"
printf '%s\n' "$STEP_BLOCK" | grep -q 'nomad/jobs/agents\*\.hcl' \
  || ac_fail "rebuild-and-deploy-agents does not discover jobspecs via the nomad/jobs/agents*.hcl glob (a hardcoded list would go stale)"

# ── It takes the shared deploy lock before deploying ────────────────────────
ac_log "checking the step takes the shared deploy lock"
printf '%s\n' "$STEP_BLOCK" | grep -q 'acceptance-deploy.lock' \
  || ac_fail "rebuild-and-deploy-agents does not use the shared acceptance-deploy.lock"
printf '%s\n' "$STEP_BLOCK" | grep -q 'flock' \
  || ac_fail "rebuild-and-deploy-agents does not flock the deploy lock"

ac_pass
