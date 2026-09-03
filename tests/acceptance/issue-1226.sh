#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1226.sh
#
# Issue #1226: the onboarding docs (disinto-factory/setup.md,
# disinto-factory/operations.md, docs/updating-factory.md) documented only
# the legacy docker-compose backend, while the production factory
# (disinto-nomad-box) runs Nomad+Vault (`disinto init --backend=nomad`).
#
# The fix makes the Nomad backend the documented recommended path:
#   - setup.md documents `init --backend=nomad` fresh install + a
#     verifiable post-init checklist, compose section marked legacy
#   - operations.md lists Nomad status/log commands next to the compose
#     ones (`nomad job status`, `nomad alloc logs`, `role status`)
#   - updating-factory.md has a Nomad update path (git pull +
#     `nomad job run <jobspec>` + agents image rebuild)
#   - release-verification.md states which backend the smoke tests
#
# This test is read-only: it greps the doc files for the required Nomad
# markers and fails if any is missing or if the compose path is no longer
# clearly marked legacy.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SETUP_MD="$REPO_ROOT/disinto-factory/setup.md"
OPS_MD="$REPO_ROOT/disinto-factory/operations.md"
SKILL_MD="$REPO_ROOT/disinto-factory/SKILL.md"
UPDATING_MD="$REPO_ROOT/docs/updating-factory.md"

for f in "$SETUP_MD" "$OPS_MD" "$SKILL_MD" "$UPDATING_MD"; do
  ac_assert_file "$f" "docs file missing: $f"
done

# ── setup.md: Nomad is the recommended fresh-install path ───────────────────
ac_log "setup.md documents init --backend=nomad"
grep -q -- '--backend=nomad' "$SETUP_MD" \
  || ac_fail "setup.md does not document 'init --backend=nomad'"

ac_log "setup.md marks the docker-compose section as legacy"
grep -qi 'legacy' "$SETUP_MD" \
  || ac_fail "setup.md does not mark the docker-compose section as legacy"

ac_log "setup.md has a Nomad post-init verification checklist"
grep -q 'nomad job status' "$SETUP_MD" \
  || ac_fail "setup.md post-init checklist does not run 'nomad job status'"
grep -q 'bin/disinto status' "$SETUP_MD" \
  || ac_fail "setup.md post-init checklist does not run 'bin/disinto status'"

# ── operations.md: Nomad status/log commands alongside compose ──────────────
ac_log "operations.md has Nomad status and log commands"
grep -q 'nomad job status' "$OPS_MD" \
  || ac_fail "operations.md has no 'nomad job status' command"
grep -q 'nomad alloc logs' "$OPS_MD" \
  || ac_fail "operations.md has no 'nomad alloc logs' command"
grep -q 'role status' "$OPS_MD" \
  || ac_fail "operations.md has no 'role status' guidance"

# ── SKILL.md: backend-aware pointers ────────────────────────────────────────
ac_log "SKILL.md points at the Nomad backend"
grep -q -- '--backend=nomad' "$SKILL_MD" \
  || ac_fail "SKILL.md does not reference the Nomad backend ('--backend=nomad')"

# ── updating-factory.md: Nomad update path ─────────────────────────────────
ac_log "updating-factory.md has a Nomad update path"
grep -q -- '--backend=nomad' "$UPDATING_MD" \
  || ac_fail "updating-factory.md does not reference the Nomad backend"
grep -q 'nomad job run' "$UPDATING_MD" \
  || ac_fail "updating-factory.md Nomad path does not use 'nomad job run'"
grep -q 'disinto/agents:local' "$UPDATING_MD" \
  || ac_fail "updating-factory.md Nomad path does not cover the agents image rebuild"

ac_pass
