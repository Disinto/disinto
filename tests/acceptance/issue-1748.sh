#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1748.sh — fix(tools): sprint-outcomes.sh is executable
#
# Issue #1748: #1676 shipped tools/sprint-outcomes.sh at 100644, but
# gardener/gardener-run.sh invokes it directly:
#
#     "$FACTORY_ROOT/tools/sprint-outcomes.sh"
#
# A 644 checkout is "Permission denied" (rc=126) — the 2026-10-04 13:11
# gardener run logged exactly that, so no soak clock started and no sprint
# outcome was written. The fix is a mode change, not content, and this test
# pins it down so it cannot silently regress.
#
# Acceptance (hermetic — no network, no mutation):
#   * AC1 git records tools/sprint-outcomes.sh at 100755
#     (`git ls-files -s`, first field). That is the mode the production
#     checkout (and the bats suite below) inherits.
#   * AC2 bats tests/tools-executable.bats passes — every tools/*.sh carries
#     the exec bit, so a future 100644 tool fails CI the instant it lands.
#
# Run via: tools/run-acceptance.sh 1748
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source tests/lib/acceptance-helpers.sh

ac_require_cmd bash git bats

# ── AC1: git records tools/sprint-outcomes.sh at 100755 ────────────────────────
ac_assert_file "$REPO_ROOT/tools/sprint-outcomes.sh" "tools/sprint-outcomes.sh is missing"
mode_line="$(git ls-files -s "$REPO_ROOT/tools/sprint-outcomes.sh")"
mode="${mode_line%% *}"
ac_assert_eq "$mode" "100755" \
  "tools/sprint-outcomes.sh is not recorded executable (mode=$mode, expected 100755): $mode_line"
ac_log "AC1 OK: git records tools/sprint-outcomes.sh at 100755"

# ── AC2: every tools/*.sh is executable (the bats suite) ───────────────────────
bats_rc=0
bats_out="$(bats tests/tools-executable.bats 2>&1)" || bats_rc=$?
ac_assert_eq "$bats_rc" "0" \
  "bats tests/tools-executable.bats failed (rc=$bats_rc): $bats_out"
ac_log "AC2 OK: every tools/*.sh is executable (bats tests/tools-executable.bats)"

ac_pass "issue #1748: sprint-outcomes.sh is executable"
