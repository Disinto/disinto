#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1752.sh — issue-1408.sh accepts the gated
# repair_tape_tick call
#
# Issue #1752: since #1713, supervisor/supervisor-run.sh calls
# repair_tape_tick inside `if [ "$RECIPE_EVAL_OK" = 1 ]`. issue-1408.sh
# looked for a column-0 call (`^repair_tape_tick$`) and failed. It now
# matches an indented call and keeps the order check against the LLM
# escalation gate. The gate itself stays #1713's contract.
#
# Acceptance (hermetic — no network, no live forge):
#   * bash tests/acceptance/issue-1408.sh exits 0
#   * bash tests/acceptance/issue-1713.sh exits 0
#
# Run via: tools/run-acceptance.sh 1752
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../lib/acceptance-helpers.sh
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

run_one "issue-1408.sh"
run_one "issue-1713.sh"

ac_pass "issue #1752: issue-1408.sh accepts the gated repair_tape_tick call"
