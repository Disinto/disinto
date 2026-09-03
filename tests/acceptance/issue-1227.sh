#!/usr/bin/env bash
# tests/acceptance/issue-1227.sh — release-smoke covers the Nomad backend
#
# Issue #1227: release-smoke only tested the docker-compose backend.
#
# Verifies (read-only — the nomad script only writes a scratch clone under
# /tmp and tears it down in its EXIT trap):
#   1. tests/release-smoke-nomad.sh exists and runs Stage A (init
#      dry-run plan validation) against a scratch clone of `main` and
#      exits 0.
#   2. Stage B SKIPs cleanly without SCRATCH_LXC_NAME (this box is the
#      Nomad box; a real Stage B run is operator-gated, not part of
#      acceptance).
#   3. release-smoke.sh wires the Nomad script in (combined summary).
#
# Run via: tools/run-acceptance.sh 1227
set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=tests/lib/acceptance-helpers.sh
source "${FACTORY_ROOT}/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git

NOMAD_SCRIPT="${FACTORY_ROOT}/tests/release-smoke-nomad.sh"
ac_assert_file "$NOMAD_SCRIPT" "tests/release-smoke-nomad.sh is missing"

ac_log "running Stage A against a scratch clone of main (Stage B forced to SKIP)"
# SCRATCH_LXC_NAME= forces the Stage B SKIP path even if the daemon's
# environment carried the variable.
OUTPUT="$(SCRATCH_LXC_NAME="" VERSION=main bash "$NOMAD_SCRIPT" 2>&1)" \
  && RC=0 || RC=$?

if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "release-smoke-nomad.sh exited ${RC} (expected 0 — Stage A pass, Stage B skip)"
fi

if printf '%s\n' "$OUTPUT" | grep -q 'SKIP: Stage B'; then
  ac_log "Stage B SKIPped cleanly as expected"
else
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "Stage B did not SKIP without SCRATCH_LXC_NAME"
fi

if printf '%s\n' "$OUTPUT" | grep -qE '^\[[0-9]+/[0-9]+\] FAIL'; then
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "nomad smoke reported a FAIL stage"
fi

if printf '%s\n' "$OUTPUT" | grep -q 'NOMAD RELEASE SMOKE: PASSED'; then
  ac_log "Stage A PASSED with the combined banner"
else
  printf '%s\n' "$OUTPUT" >&2
  ac_fail "missing the 'NOMAD RELEASE SMOKE: PASSED' summary banner"
fi

if grep -q 'release-smoke-nomad.sh' "${FACTORY_ROOT}/tests/release-smoke.sh"; then
  ac_log "release-smoke.sh wires in the Nomad backend"
else
  ac_fail "tests/release-smoke.sh does not invoke release-smoke-nomad.sh"
fi

ac_pass
