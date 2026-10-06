#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1825.sh
#
# Issue #1825: a non-dev label on an in-progress issue must leave the scan.
#
# dev/dev-poll.sh used to log "skipping" and set OTHER_AGENT_INPROGRESS=true
# without leaving the iteration. The assignee block below still ran, so a
# $BOT_USER-assigned in-progress issue labelled awaiting-live-verification
# (or any other non-dev label) was relaunched — review fix, CI fix, or
# stale-branch / post-crash recovery. The stale sweep was already gated on
# the flag; that unassigned path must stay.
#
# Hermetic: no network. Structural checks on dev/dev-poll.sh.
#
# Acceptance: `bash tests/acceptance/issue-1825.sh` exits 0 and calls ac_pass.
# Run via `tools/run-acceptance.sh 1825`.
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

ac_log "bash -n dev/dev-poll.sh"
bash -n "$POLL" || ac_fail "bash -n dev/dev-poll.sh failed"
if command -v shellcheck >/dev/null 2>&1; then
  ac_log "shellcheck --severity=warning dev/dev-poll.sh"
  shellcheck --severity=warning "$POLL" \
    || ac_fail "shellcheck --severity=warning dev/dev-poll.sh failed"
else
  ac_log "shellcheck not on PATH — skipped (run it in CI)"
fi

# In-progress scan: "checking for in-progress issues" through the stuck-PR scan.
START="$(grep -n 'checking for in-progress issues' "$POLL" | head -n1 | cut -d: -f1)"
END="$(grep -n 'checking for stuck PRs' "$POLL" | head -n1 | cut -d: -f1)"
[ -n "$START" ] || ac_fail "could not find the in-progress scan"
[ -n "$END" ] || ac_fail "could not find the end of the in-progress scan"
[ "$START" -lt "$END" ] || ac_fail "in-progress scan (line $START) must precede the stuck-PR scan (line $END)"

line_of() {
  local pat="$1"
  { grep -n -F -- "$pat" "$POLL" || true; } \
    | awk -F: -v s="$START" -v e="$END" '$1 > s && $1 < e { print $1; exit }'
}

NON_DEV='if ! issue_is_dev_claimable "$issue_labels"; then'
ASSIGNEE='if [ -n "$assignee" ]; then'
STALE_GATE='if [ "$BLOCKED_BY_INPROGRESS" = false ] && [ "$OTHER_AGENT_INPROGRESS" = false ]; then'
STALE_CALL='handle_stale_in_progress "$ISSUE_NUM"'
OPEN_PR_GUARD='if [ "$OPEN_PR" = false ] && [ "$BLOCKED_BY_INPROGRESS" = false ]; then'
SPAWN='("${SCRIPT_DIR}/dev-agent.sh"'
REVIEW_FIX='(review fix)'
CI_FIX='(CI fix)'
STALE_RECOVERY='(stale-branch recovery)'
CRASH_RECOVERY='(post-crash recovery)'

NON_DEV_LN="$(line_of "$NON_DEV")"
ASSIGN_LN="$(line_of "$ASSIGNEE")"
GATE_LN="$(line_of "$STALE_GATE")"
STALE_LN="$(line_of "$STALE_CALL")"
OPEN_LN="$(line_of "$OPEN_PR_GUARD")"
[ -n "$NON_DEV_LN" ] || ac_fail "non-dev label check not found in the in-progress scan"
[ -n "$ASSIGN_LN" ] || ac_fail "assignee block not found in the in-progress scan"
[ -n "$GATE_LN" ] || ac_fail "stale-sweep gate not found in the in-progress scan"
[ -n "$STALE_LN" ] || ac_fail "handle_stale_in_progress call not found in the in-progress scan"
[ -n "$OPEN_LN" ] || ac_fail "OPEN_PR=false guard not found in the in-progress scan"

# The skip must sit inside a loop, and continue must leave that iteration
# before the assignee block (the spawn paths) runs.
LOOP_LN="$(awk -v s="$START" -v e="$NON_DEV_LN" \
  'NR > s && NR < e && /^([[:space:]]*)(for|while)[[:space:]]/ { line = NR } END { print line }' \
  "$POLL")"
[ -n "$LOOP_LN" ] \
  || ac_fail "non-dev label check must sit inside a for/while loop so continue can leave the iteration"

DONE_LN="$(awk -v s="$NON_DEV_LN" -v e="$END" \
  'NR > s && NR < e && /^[[:space:]]*done[[:space:]]*$/ { print NR; exit }' \
  "$POLL")"
[ -n "$DONE_LN" ] || ac_fail "in-progress loop has no done before the stuck-PR scan"
[ "$LOOP_LN" -lt "$NON_DEV_LN" ] && [ "$DONE_LN" -gt "$ASSIGN_LN" ] \
  || ac_fail "non-dev check and assignee block must both be inside the in-progress loop"

CONT_LN="$(awk -v s="$NON_DEV_LN" -v e="$ASSIGN_LN" \
  'NR > s && NR < e && /^[[:space:]]*continue[[:space:]]*$/ { print NR; exit }' \
  "$POLL")"
[ -n "$CONT_LN" ] \
  || ac_fail "non-dev-label skip must continue out of the loop before the assignee block (got none between $NON_DEV_LN and $ASSIGN_LN)"

# No dev-agent spawn between the skip and its continue.
SPAWN_IN_SKIP="$(awk -v s="$NON_DEV_LN" -v e="$CONT_LN" \
  'NR > s && NR < e && index($0, "dev-agent.sh") { print NR }' \
  "$POLL")"
[ -z "$SPAWN_IN_SKIP" ] \
  || ac_fail "dev-agent.sh spawn sits inside the non-dev skip (line $SPAWN_IN_SKIP) — continue must precede every spawn"

# Review-fix, CI-fix, and both recovery spawns stay after the continue,
# inside the loop, so a continued iteration never reaches them.
for pat in "$REVIEW_FIX" "$CI_FIX" "$STALE_RECOVERY" "$CRASH_RECOVERY"; do
  ln="$(line_of "$pat")"
  [ -n "$ln" ] || ac_fail "in-progress scan no longer logs $pat"
  [ "$ln" -gt "$CONT_LN" ] && [ "$ln" -lt "$DONE_LN" ] \
    || ac_fail "$pat (line $ln) must follow the non-dev continue (line $CONT_LN) and precede done (line $DONE_LN)"
done

# Every in-progress dev-agent.sh spawn follows the continue.
SPAWN_BEFORE="$(awk -v s="$LOOP_LN" -v e="$CONT_LN" \
  'NR > s && NR <= e && index($0, "dev-agent.sh") && index($0, "SCRIPT_DIR") { c++ } END { print c+0 }' \
  "$POLL")"
[ "$SPAWN_BEFORE" = "0" ] \
  || ac_fail "in-progress loop spawns dev-agent.sh at or before the non-dev continue"

# Unassigned stale sweep is unchanged: still behind both gates, after the skip.
[ "$GATE_LN" -gt "$CONT_LN" ] \
  || ac_fail "stale-sweep gate (line $GATE_LN) must remain after the non-dev continue (line $CONT_LN)"
[ "$OPEN_LN" -gt "$GATE_LN" ] \
  || ac_fail "OPEN_PR=false guard (line $OPEN_LN) must remain inside the OTHER_AGENT_INPROGRESS gate (line $GATE_LN)"
[ "$STALE_LN" -gt "$OPEN_LN" ] \
  || ac_fail "handle_stale_in_progress (line $STALE_LN) must remain under the OPEN_PR=false guard (line $OPEN_LN)"

ac_log "dev/AGENTS.md documents the non-dev continue (#1825)"
DOC_SENTENCE='the scan `continue`s past that issue (#1825)'
grep -qF "$DOC_SENTENCE" "$DOC" \
  || ac_fail "dev/AGENTS.md must say the in-progress scan continues past a non-dev label (#1825)"
grep -qF 'awaiting-live-verification' "$DOC" \
  || ac_fail "dev/AGENTS.md must still name awaiting-live-verification as a skipped label"

ac_pass "issue #1825: non-dev in-progress skip continues before any dev-agent spawn; unassigned stale sweep unchanged"
