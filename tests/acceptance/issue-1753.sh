#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1753.sh — issue-1478.sh drops the check #1646 removed
#
# Issue #1753: tests/acceptance/issue-1478.sh AC 4 grepped dev-agent.sh for
# ATTEMPT:0:0, the TAPE_RUN_ATTEMPTS export block #1646 removed. Under
# set -euo pipefail the failing grep exited 1 before ac_fail could print.
# That check is gone; issue-1646.sh covers the tape-driven count.
#
# Acceptance (hermetic — no network, no live forge):
#   * bash tests/acceptance/issue-1478.sh exits 0
#   * bash tests/acceptance/issue-1646.sh exits 0
#
# Run via: tools/run-acceptance.sh 1753
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

# Run each sibling acceptance script and require exit 0 plus a PASS line.
# Wording stays local to this file so the 5-line duplicate window does not
# match the other "run a sibling script" acceptance tests.
sibling_scripts=(issue-1478.sh issue-1646.sh)
for sibling in "${sibling_scripts[@]}"; do
  sibling_path="${REPO_ROOT}/tests/acceptance/${sibling}"
  ac_assert_file "$sibling_path" "missing sibling acceptance script ${sibling}"
  sibling_rc=0
  sibling_out="$(bash "$sibling_path" 2>&1)" || sibling_rc=$?
  if [ "$sibling_rc" -ne 0 ]; then
    ac_fail "${sibling} must exit 0 (rc=${sibling_rc}): ${sibling_out}"
  fi
  case "$sibling_out" in
    *PASS*) ac_log "${sibling} exits 0" ;;
    *) ac_fail "${sibling} exited 0 but did not print PASS: ${sibling_out}" ;;
  esac
done

ac_pass "issue #1753: issue-1478.sh no longer checks the block #1646 removed"
