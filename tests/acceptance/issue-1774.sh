#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1774.sh — docs: stale TAPE_RUN_ATTEMPTS = ATTEMPT+1
#
# Issue #1774: lib/formula-session.sh and tests/acceptance/issue-1478.sh still
# described the export that #1646 removed: TAPE_RUN_ATTEMPTS as ATTEMPT+1
# taken from dev-agent.sh's branch-count block. Since #1646 dev-agent.sh
# exports DEV_FAILED_ATTEMPTS + 1 — the picked proposal's failed tape outcomes
# plus one, a 1-based integer. Only the prose about where the value came from
# was stale; the resolver (prefer $TAPE_RUN_ATTEMPTS when positive integer,
# else 1) is unchanged and correct.
#
# After: the two stale comments are rewritten to cite #1646 and the
# DEV_FAILED_ATTEMPTS + 1 source. No code line changed, no branch-count export
# restored.
#
# Acceptance (hermetic — read-only file checks, no network, no agents, no
# tape process driven):
#   1. Neither lib/formula-session.sh nor tests/acceptance/issue-1478.sh still
#      documents the removed export: no `ATTEMPT+1`, `branch-count`, or
#      `ls-remote` anywhere in either file.
#   2. lib/formula-session.sh documents the tape-driven count exactly twice
#      as `DEV_FAILED_ATTEMPTS + 1` (the header paragraph and the
#     _FORMULA_TAPE_ATTEMPTS assignment comment).
#
# Run via: tools/run-acceptance.sh 1774
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

FORMULA_SESSION="$REPO_ROOT/lib/formula-session.sh"
ISSUE_1478="$REPO_ROOT/tests/acceptance/issue-1478.sh"
ac_assert_file "$FORMULA_SESSION" "lib/formula-session.sh must exist"
ac_assert_file "$ISSUE_1478" "tests/acceptance/issue-1478.sh must exist"

# ── AC 1: no stale reference to the removed ATTEMPT+1 / branch-count /
# ls-remote export remains in either file ─────────────────────────────────────
stale_rc=0
stale="$(grep -nE 'ATTEMPT\+1|branch-count|ls-remote' "$FORMULA_SESSION" "$ISSUE_1478" 2>&1)" \
  || stale_rc=$?
[ "$stale_rc" -eq 1 ] \
  || ac_fail "stale export reference(s) remain (grep rc=${stale_rc}): ${stale}"
ac_log "AC 1 OK: no ATTEMPT+1 / branch-count / ls-remote in either file"

# ── AC 2: the tape-driven count is documented exactly twice as
# DEV_FAILED_ATTEMPTS + 1 ─────────────────────────────────────────────────────
count="$(grep -c 'DEV_FAILED_ATTEMPTS + 1' "$FORMULA_SESSION")"
ac_assert_eq "$count" "2" \
  "lib/formula-session.sh must document DEV_FAILED_ATTEMPTS + 1 exactly twice (got $count)"
ac_log "AC 2 OK: lib/formula-session.sh documents the tape-driven count $count times"

ac_pass "issue #1774: stale ATTEMPT+1 / branch-count / ls-remote comments replaced with the #1646 tape-driven count"
