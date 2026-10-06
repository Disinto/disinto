#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1810.sh — Nomad job headers no longer say compose is live
#
# Issue #1810: six jobspecs (and agents.hcl) still claimed docker-compose.yml
# is the factory's live stack "until cutover". The production factory runs
# the Nomad+Vault backend (docs/updating-factory.md). An agent trusting the
# stale header might edit the generated compose stack instead of the jobspec.
#
# This test is read-only: it greps nomad/jobs/*.hcl. It does not submit a
# job or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1810.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

JOBS_DIR="$REPO_ROOT/nomad/jobs"
ac_assert_file "$JOBS_DIR" "nomad/jobs must exist"

ac_log "checking no jobspec still claims docker-compose is the live stack until cutover"
stale="$(grep -nE 'Not the runtime yet|until cutover' "$JOBS_DIR"/*.hcl || true)"
if [ -n "$stale" ]; then
  printf '%s\n' "$stale" >&2
  ac_fail "a jobspec still claims docker-compose.yml is the live stack until cutover"
fi

live_specs=(
  forgejo.hcl
  staging.hcl
  woodpecker-server.hcl
  agents-dev-qwen.hcl
  agents-review-qwen.hcl
  agents-supervisor-opus.hcl
)

ac_log "checking the six live jobspecs name the Nomad+Vault backend"
for spec in "${live_specs[@]}"; do
  path="$JOBS_DIR/$spec"
  ac_assert_file "$path" "$spec must exist"
  if ! grep -q 'production factory runs the Nomad+Vault' "$path"; then
    ac_fail "$spec header must name the Nomad+Vault backend as the live stack"
  fi
  if ! grep -q 'not in the generated docker-compose.yml' "$path"; then
    ac_fail "$spec header must point service changes at the jobspec, not docker-compose.yml"
  fi
done

ac_log "checking agents.hcl does not call itself the not-yet runtime"
if ! grep -q 'Stopped on the production factory' "$JOBS_DIR/agents.hcl"; then
  ac_fail "agents.hcl must say it is stopped on the production factory, not pending cutover"
fi

# Init's DEPLOY_ORDER never passes these names to deploy.sh. `--with agents`
# submits agents.hcl. Claiming deploy.sh registers them invites a second
# polling loop beside the live per-role jobs (#1522).
per_role_specs=(
  agents-dev-qwen.hcl
  agents-review-qwen.hcl
  agents-supervisor-opus.hcl
)
ac_log "checking per-role jobs are not claimed to be submitted by deploy.sh"
for spec in "${per_role_specs[@]}"; do
  path="$JOBS_DIR/$spec"
  if grep -q 'submits this spec with' "$path" || grep -q 'deploy.sh).' "$path"; then
    ac_fail "$spec must not claim lib/init/nomad/deploy.sh submits it"
  fi
  if ! grep -q 'not lib/init/nomad/deploy.sh' "$path"; then
    ac_fail "$spec must say deploy.sh does not register it"
  fi
  if ! grep -q -- '--with agents`' "$path" || ! grep -q 'not this spec' "$path"; then
    ac_fail "$spec must say --with agents submits agents.hcl, not this spec"
  fi
done

echo PASS
