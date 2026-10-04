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

ac_require_cmd bash

run_one() {
  local name="$1"
  local target="$REPO_ROOT/tests/acceptance/${name}"
  ac_assert_file "$target" "tests/acceptance/${name} not found"
  ac_log "bash tests/acceptance/${name}"
  local rc=0
  local out
  out="$(bash "$target" 2>&1)" || rc=$?
  ac_assert_eq "$rc" "0" \
    "${name} must exit 0 (rc=$rc): $out"
  case "$out" in
    *PASS*) ;;
    *) ac_fail "${name} did not print PASS: $out" ;;
  esac
  ac_log "${name} exits 0"
}

run_one "issue-1478.sh"
run_one "issue-1646.sh"

ac_pass "issue #1753: issue-1478.sh no longer checks the block #1646 removed"
