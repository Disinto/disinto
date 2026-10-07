#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1907.sh — retire the architect's retired states
#
# Issue #1907 (chore/architect): the architect no longer merges or files — the
# owner's merge is the decision, and the milestone + tape track the sprint
# (#1892). The three states left over from #901 (approved_idle, tracking,
# mergeable) and the tracking green gate are deleted from
# architect/architect-run.sh, and their documentation from architect/AGENTS.md.
# Only the q_and_a state remains; the owner merges the PR or closes it.
#
# Verifies the three acceptance criteria (all checks read-only — no forge, no
# nomad, no repo mutation; the issue-1335 re-run is itself read-only):
#   1. architect/architect-run.sh contains none of the retired strings
#      (states, helpers, green gate, /merge path) and still parses (bash -n).
#   2. architect/AGENTS.md carries no retired-state or APPROVED-review
#      documentation.
#   3. The surviving issue-1335 acceptance test still passes.
#
# Run via: tools/run-acceptance.sh 1907
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

ARCHITECT_RUN="$REPO_ROOT/architect/architect-run.sh"
ARCHITECT_DOCS="$REPO_ROOT/architect/AGENTS.md"
AC_1335="$REPO_ROOT/tests/acceptance/issue-1335.sh"

ac_assert_file "$ARCHITECT_RUN" "architect/architect-run.sh is missing"
ac_assert_file "$ARCHITECT_DOCS" "architect/AGENTS.md is missing"
ac_assert_file "$AC_1335" "tests/acceptance/issue-1335.sh is missing"

# ── 1. Retired strings are gone from architect-run.sh, and it parses ─────
# The patterns are exactly those from the acceptance criteria. The grep is
# scoped to the two architect files, so this test file (a .sh under
# tests/acceptance/) cannot self-match.
ac_log "checking architect/architect-run.sh is free of retired strings"
# shellcheck disable=SC2086
for p in approved_idle has_approved_review check_subissue_green dispatch_tracking \
         dispatch_mergeable merge_pr TRACKING_GREEN_DEF 'Filed:' '/merge'; do
  MATCHES="$(grep -nE -- "$p" "$ARCHITECT_RUN" || true)"
  [ -z "$MATCHES" ] \
    || { ac_log "retired string '$p' still in architect/architect-run.sh:"; \
          echo "$MATCHES" >&2; \
          ac_fail "architect/architect-run.sh still matches '$p'"; }
done
bash -n "$ARCHITECT_RUN" 2>/dev/null \
  || ac_fail "architect/architect-run.sh fails bash -n"
ac_log "architect/architect-run.sh: no retired strings, parses"

# ── 2. No retired-state documentation in architect/AGENTS.md ─────────────
ac_log "checking architect/AGENTS.md is free of retired-state documentation"
# shellcheck disable=SC2086
for p in approved_idle '\[tracking\]' '\[mergeable\]' '## Filed' APPROVED; do
  MATCHES="$(grep -nE -- "$p" "$ARCHITECT_DOCS" || true)"
  [ -z "$MATCHES" ] \
    || { ac_log "retired pattern '$p' still in architect/AGENTS.md:"; \
          echo "$MATCHES" >&2; \
          ac_fail "architect/AGENTS.md still matches '$p'"; }
done
ac_log "architect/AGENTS.md: no retired-state documentation"

# ── 3. The surviving issue-1335 acceptance test still passes ─────────────
ac_log "re-running tests/acceptance/issue-1335.sh"
if bash "$AC_1335" >/dev/null; then
  ac_log "issue-1335.sh: PASS"
else
  RC=$?
  ac_fail "tests/acceptance/issue-1335.sh now fails (exit $RC)"
fi

ac_pass
