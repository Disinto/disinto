#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1846.sh
#
# Issue #1846: chore(edge): the edge job stops mounting claude-shared.
#
# The owner decision (2026-10-06) moved the reproduce/triage/verify sidecars
# to dsh against the local model (DSH_BASE_URL, the think-budget proxy); they
# never run `claude -p`, so the dispatcher no longer hands them the Claude CLI
# or an OAuth session. The edge job's `claude-shared` volume mount — kept only
# to bind-mount the OAuth session into sidecars — is dead weight (#1803,
# #1841) and is removed. This issue's job: no reference to `claude-shared`
# remains in `nomad/jobs/edge.hcl`, and no jobspec under `nomad/jobs/` uses
# it.
#
# The `claude-shared` host_volume declaration in `nomad/client.hcl` and its
# entry in `lib/init/nomad/cluster-up.sh` are deliberately kept (removal is a
# separate step), so those two files legitimately still mention the name.
#
# Contract under test (read-only, pure grep over the checkout):
#   1. `grep -n 'claude-shared' nomad/jobs/edge.hcl` prints nothing.
#   2. `grep -rln 'claude-shared' nomad/jobs/` prints nothing.
#
# Read-only: greps over the checkout; no job is dispatched, no network reached.
#
# Run via: tools/run-acceptance.sh 1846
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

EDGE_HCL="$REPO_ROOT/nomad/jobs/edge.hcl"
JOBS_DIR="$REPO_ROOT/nomad/jobs"
ac_assert_file "$EDGE_HCL" "nomad/jobs/edge.hcl must exist"
ac_assert_file "$JOBS_DIR" "nomad/jobs must exist"

# ── AC1: edge.hcl no longer references claude-shared ──────────────────────────
ac_log "AC1: grep -n claude-shared nomad/jobs/edge.hcl must print nothing"
MATCHES="$(grep -n 'claude-shared' "$EDGE_HCL" || true)"
ac_assert_eq "$MATCHES" "" \
  "edge.hcl must not reference claude-shared (got: $MATCHES)"

# ── AC2: no jobspec under nomad/jobs/ references claude-shared ────────────────
ac_log "AC2: grep -rln claude-shared nomad/jobs/ must print nothing"
MATCHES="$(grep -rln 'claude-shared' "$JOBS_DIR" || true)"
ac_assert_eq "$MATCHES" "" \
  "no jobspec under nomad/jobs/ may reference claude-shared (got: $MATCHES)"

ac_pass
