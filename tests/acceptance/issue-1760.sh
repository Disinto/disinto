#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1760.sh
#
# Issue #1760: operator docs still restart the non-live all-roles agents job.
# nomad/jobs/agents.hcl is stopped on the production box; restarting or
# running it starts a second polling loop beside the per-role agents-* jobs
# (#1522). docs/agents-llama.md, docs/nomad-migration.md, and
# docs/updating-factory.md must restart whichever agent jobs are running,
# never the stopped all-roles job.
#
# This test is read-only: it greps the three docs.
#
# Run via: tools/run-acceptance.sh 1760
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

LLAMA_MD="$REPO_ROOT/docs/agents-llama.md"
MIGRATION_MD="$REPO_ROOT/docs/nomad-migration.md"
UPDATING_MD="$REPO_ROOT/docs/updating-factory.md"

for f in "$LLAMA_MD" "$MIGRATION_MD" "$UPDATING_MD"; do
  ac_assert_file "$f" "docs file missing: $f"
done

ac_log "docs do not restart or run the stopped all-roles agents job"
stale="$(grep -nE 'nomad job restart agents$|nomad/jobs/agents\.hcl$' \
  "$LLAMA_MD" "$MIGRATION_MD" "$UPDATING_MD" || true)"
[ -z "$stale" ] \
  || ac_fail "docs still name the stopped all-roles agents job: ${stale}"

ac_log "updating-factory.md expected-jobs list does not start with agents"
expected="$(grep -n '# Expected: agents,' "$UPDATING_MD" || true)"
[ -z "$expected" ] \
  || ac_fail "updating-factory.md still lists the all-roles agents job: ${expected}"

ac_log "updating-factory.md skips the all-roles agents jobspec"
# The needle is a literal from the doc; $job must not expand.
# shellcheck disable=SC2016
skip_count="$(grep -cF '[ "$job" = agents ] && continue' "$UPDATING_MD" || true)"
[ "$skip_count" = 1 ] \
  || ac_fail "updating-factory.md must skip the agents job exactly once (got: ${skip_count})"

ac_pass
