#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1227.sh
#
# Issue #1227: release-smoke only tested the docker-compose backend; the
# production factory (and the planned second instance) run the Nomad+Vault
# backend, so a tagged release was never tested on that path.
#
# Verifies (Stage A of tests/release-smoke-nomad.sh is read-only — it writes
# only a scratch clone under /tmp and tears it down in its EXIT trap):
#   1. Stage A passes against a scratch clone of `main` (dry-run plan
#      validation, exit 0).
#   2. Stage B SKIPs cleanly without SCRATCH_LXC_NAME (the real fresh-LXC
#      run is operator-gated — its pass/skip result is recorded by the
#      operator in the acceptance commit, not run here).
#   3. release-smoke.sh wires the Nomad script in (combined summary).
#
# Run via: tools/run-acceptance.sh 1227
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git

NOMAD_SCRIPT="$REPO_ROOT/tests/release-smoke-nomad.sh"
ac_assert_file "$NOMAD_SCRIPT" "tests/release-smoke-nomad.sh is missing"

ac_log "running Stage A against a scratch clone of main (Stage B forced to SKIP)"
# SCRATCH_LXC_NAME="" forces the Stage B SKIP path even if the daemon's
# environment carried the variable.
OUTPUT="$(SCRATCH_LXC_NAME="" VERSION=main bash "$NOMAD_SCRIPT" 2>&1)" && RC=0 || RC=$?

if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "release-smoke-nomad.sh exited ${RC} (expected 0 — Stage A pass, Stage B skip)"
fi

if grep -q 'SKIP: Stage B' <<< "$OUTPUT"; then
  ac_log "Stage B SKIPped cleanly as expected"
else
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "Stage B did not SKIP without SCRATCH_LXC_NAME"
fi

if grep -qE '^\[[0-9]+/[0-9]+\] FAIL' <<< "$OUTPUT"; then
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "nomad smoke reported a FAIL stage"
fi

if grep -q 'NOMAD RELEASE SMOKE: PASSED' <<< "$OUTPUT"; then
  ac_log "Stage A PASSED with the combined banner"
else
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "missing the 'NOMAD RELEASE SMOKE: PASSED' summary banner"
fi

if grep -q 'release-smoke-nomad.sh' "$REPO_ROOT/tests/release-smoke.sh"; then
  ac_log "release-smoke.sh wires in the Nomad backend"
else
  ac_fail "tests/release-smoke.sh does not invoke release-smoke-nomad.sh"
fi

ac_pass
