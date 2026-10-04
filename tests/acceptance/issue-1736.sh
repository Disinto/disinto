#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1736.sh
#
# Issue #1736: the stuck-PR scan leaves another agent's failed CI alone.
#
# dev/dev-poll.sh's stuck-PR loop used to skip a foreign assignee only on the
# REQUEST_CHANGES branch. The CI-failure branch still called
# handle_ci_exhaustion, so a poll spent another agent's CI-fix attempts and
# could block their issue. The assignee lookup and skip now sit once, before
# both branches and before any handle_ci_exhaustion call in that loop.
#
# Hermetic: no network. Structural checks with grep and awk on dev/dev-poll.sh.
#
# Acceptance: `bash tests/acceptance/issue-1736.sh` exits 0 and calls ac_pass.
# Run via `tools/run-acceptance.sh 1736`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk
POLL="$REPO_ROOT/dev/dev-poll.sh"
DOC="$REPO_ROOT/dev/AGENTS.md"
ac_assert_file "$POLL" "dev/dev-poll.sh is present"
ac_assert_file "$DOC" "dev/AGENTS.md is present"

# --- syntax / lint (AC) -------------------------------------------------------
ac_log "bash -n dev/dev-poll.sh"
bash -n "$POLL" || ac_fail "bash -n dev/dev-poll.sh failed"
if command -v shellcheck >/dev/null 2>&1; then
  ac_log "shellcheck --severity=warning dev/dev-poll.sh"
  shellcheck --severity=warning "$POLL" \
    || ac_fail "shellcheck --severity=warning dev/dev-poll.sh failed"
else
  ac_log "shellcheck not on PATH — skipped (run it in CI)"
fi

# --- stuck-PR loop bounds -----------------------------------------------------
# PRIORITY 1.5 ("checking for stuck PRs") through the PRIORITY 2 backlog scan.
START="$(grep -n 'checking for stuck PRs' "$POLL" | head -n1 | cut -d: -f1)"
END="$(grep -n 'scanning backlog for ready issues' "$POLL" | head -n1 | cut -d: -f1)"
[ -n "$START" ] || ac_fail "could not find the stuck-PR scan (checking for stuck PRs)"
[ -n "$END" ] || ac_fail "could not find the end of the stuck-PR scan"
[ "$START" -lt "$END" ] || ac_fail "stuck-PR scan (line $START) must precede the backlog scan (line $END)"

LOOP="$(awk -v s="$START" -v e="$END" 'NR > s && NR < e' "$POLL")"
[ -n "$LOOP" ] || ac_fail "stuck-PR loop extract is empty"

# Lines of interest inside the loop, as file line numbers (grep -n).
# First field is the line number; the rest of the line is ignored for order.
# grep exits 1 on no match; keep the helper successful so set -e reports via ac_fail.
line_of() {
  local pat="$1"
  { grep -n -F -- "$pat" "$POLL" || true; } \
    | awk -F: -v s="$START" -v e="$END" '$1 > s && $1 < e { print $1; exit }'
}
count_of() {
  local pat="$1"
  { grep -n -F -- "$pat" "$POLL" || true; } \
    | awk -F: -v s="$START" -v e="$END" '$1 > s && $1 < e' \
    | wc -l | tr -d '[:space:]'
}

ASSIGNEE_IF='if [ -n "$assignee" ] && [ "$assignee" != "$BOT_USER" ]; then'
CHANGES_IF='if [ "${HAS_CHANGES:-0}" -gt 0 ]'
CI_FAILED='elif ci_failed "$CI_STATE"'
EXHAUST='handle_ci_exhaustion'
SKIP_LOG='assigned to ${assignee} — skipping (not mine)'
OLD_LOG='REQUEST_CHANGES but assigned to'
STUCK_COMMENT='# Stuck: REQUEST_CHANGES or CI failure -> spawn agent'
ISSUE_LOOKUP='${API}/issues/${STUCK_ISSUE}'

ac_log "assignee check appears once, before both branches and handle_ci_exhaustion"
ASSIGN_N="$(count_of "$ASSIGNEE_IF")"
[ "$ASSIGN_N" = "1" ] \
  || ac_fail "stuck-PR loop must contain the assignee check exactly once (got $ASSIGN_N)"

ASSIGN_LN="$(line_of "$ASSIGNEE_IF")"
CHANGES_LN="$(line_of "$CHANGES_IF")"
CI_LN="$(line_of "$CI_FAILED")"
EXHAUST_LN="$(line_of "$EXHAUST")"
COMMENT_LN="$(line_of "$STUCK_COMMENT")"
LOOKUP_LN="$(line_of "$ISSUE_LOOKUP")"

[ -n "$ASSIGN_LN" ] || ac_fail "assignee check not found in the stuck-PR loop"
[ -n "$CHANGES_LN" ] || ac_fail "REQUEST_CHANGES branch not found in the stuck-PR loop"
[ -n "$CI_LN" ] || ac_fail "ci_failed branch not found in the stuck-PR loop"
[ -n "$EXHAUST_LN" ] || ac_fail "handle_ci_exhaustion not found in the stuck-PR loop"
[ -n "$COMMENT_LN" ] || ac_fail "stuck-PR spawn comment not found in the stuck-PR loop"
[ -n "$LOOKUP_LN" ] || ac_fail "issue lookup not found in the stuck-PR loop"

# grep -n line order: lookup + skip, then the shared comment, then branches.
[ "$LOOKUP_LN" -lt "$ASSIGN_LN" ] \
  || ac_fail "issue lookup (line $LOOKUP_LN) must precede the assignee check (line $ASSIGN_LN)"
[ "$ASSIGN_LN" -lt "$COMMENT_LN" ] \
  || ac_fail "assignee check (line $ASSIGN_LN) must precede the spawn comment (line $COMMENT_LN)"
[ "$COMMENT_LN" -lt "$CHANGES_LN" ] \
  || ac_fail "spawn comment (line $COMMENT_LN) must precede the REQUEST_CHANGES branch (line $CHANGES_LN)"
[ "$ASSIGN_LN" -lt "$CHANGES_LN" ] \
  || ac_fail "assignee check (line $ASSIGN_LN) must precede the REQUEST_CHANGES branch (line $CHANGES_LN)"
[ "$ASSIGN_LN" -lt "$CI_LN" ] \
  || ac_fail "assignee check (line $ASSIGN_LN) must precede the ci_failed branch (line $CI_LN)"
[ "$ASSIGN_LN" -lt "$EXHAUST_LN" ] \
  || ac_fail "assignee check (line $ASSIGN_LN) must precede handle_ci_exhaustion (line $EXHAUST_LN)"

# Every handle_ci_exhaustion in the loop is after the skip, not only the first.
EXHAUST_BEFORE="$({ grep -n -F -- "$EXHAUST" "$POLL" || true; } \
  | awk -F: -v s="$START" -v e="$END" -v a="$ASSIGN_LN" '$1 > s && $1 < e && $1 <= a' \
  | wc -l | tr -d '[:space:]')"
[ "$EXHAUST_BEFORE" = "0" ] \
  || ac_fail "handle_ci_exhaustion appears at or before the assignee check in the stuck-PR loop"

# The skip must continue, so a foreign PR never falls into either branch.
SKIP_CONT="$(awk -v s="$ASSIGN_LN" -v e="$COMMENT_LN" 'NR > s && NR < e && /continue/ { print NR; exit }' "$POLL")"
[ -n "$SKIP_CONT" ] \
  || ac_fail "assignee skip must continue before the REQUEST_CHANGES/ci_failed branches"

ac_log "log line present; old REQUEST_CHANGES-only skip line gone from this loop"
SKIP_N="$(count_of "$SKIP_LOG")"
[ "$SKIP_N" = "1" ] \
  || ac_fail "stuck-PR loop must log 'assigned to \${assignee} — skipping (not mine)' once (got $SKIP_N)"
OLD_N="$(count_of "$OLD_LOG")"
[ "$OLD_N" = "0" ] \
  || ac_fail "stuck-PR loop still has the old 'REQUEST_CHANGES but assigned to' line ($OLD_N)"

# The old stuck-PR wording must not survive anywhere in the file.
if grep -qF 'PR #${PR_NUM} (issue #${STUCK_ISSUE}) REQUEST_CHANGES but assigned to' "$POLL"; then
  ac_fail "old stuck-PR log line 'REQUEST_CHANGES but assigned to' is still present"
fi

# --- doc (review formula 3b) --------------------------------------------------
# After the first sentence of the Per-agent open-PR gate paragraph.
ac_log "dev/AGENTS.md names the stuck-PR assignee skip (#1736)"
DOC_SENTENCE="The stuck-PR scan likewise skips a PR whose issue is assigned to another agent, for review fixes and CI fixes alike, so it never spends another agent's CI-fix attempts (#1736)."
DOC_FLAT="$(tr '\n' ' ' < "$DOC" | tr -s ' ')"
printf '%s\n' "$DOC_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "dev/AGENTS.md must document the stuck-PR assignee skip (#1736)"
# First sentence ends at the BOT_USER filter; the new sentence follows it,
# still before the rest of the paragraph ("Other agents'").
GATE='**Per-agent open-PR gate**:'
FIRST='assigned to this agent (`$BOT_USER`).'
REST="Other agents'"
awk -v gate="$GATE" -v first="$FIRST" -v sentence="$DOC_SENTENCE" -v rest="$REST" '
  {
    g = index($0, gate)
    if (g == 0) exit 1
    tail = substr($0, g)
    f = index(tail, first)
    s = index(tail, sentence)
    r = index(tail, rest)
    if (f > 0 && s > f && r > s) exit 0
    exit 1
  }
' <<<"$DOC_FLAT" \
  || ac_fail "stuck-PR sentence must follow the first Per-agent open-PR gate sentence and precede Other agents"

ac_pass "issue #1736: stuck-PR scan skips another agent's PR before CI-fix attempts"
