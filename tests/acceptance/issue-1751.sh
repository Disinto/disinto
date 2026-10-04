#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1751.sh — issue-1295.sh checks the experiment
# template's current label
#
# Issue #1751: #1337 changed .forgejo/ISSUE_TEMPLATE/experiment.yaml to
# auto-label `action`. tests/acceptance/issue-1295.sh still pinned
# `- experiment`, so it failed on main. The assertion now expects `action`
# (and the PyYAML bonus check rejects `experiment` and `backlog`).
#
# Acceptance (hermetic — no network, no live forge):
#   * bash tests/acceptance/issue-1295.sh exits 0
#
# Run via: tools/run-acceptance.sh 1751
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash

TARGET="$REPO_ROOT/tests/acceptance/issue-1295.sh"
ac_assert_file "$TARGET" "tests/acceptance/issue-1295.sh not found"

ac_log "bash tests/acceptance/issue-1295.sh"
rc=0
out="$(bash "$TARGET" 2>&1)" || rc=$?
ac_assert_eq "$rc" "0" \
  "issue-1295.sh must exit 0 (rc=$rc): $out"
case "$out" in
  *PASS*) ;;
  *) ac_fail "issue-1295.sh did not print PASS: $out" ;;
esac
ac_log "issue-1295.sh exits 0"

ac_pass "issue #1751: issue-1295.sh checks the experiment template's current label"
