#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1671.sh
#
# Issue #1671: fix(dev): a chore PR never closes an issue it mentions.
#
# Contract under test (dev/dev-poll.sh, extract_issue_from_pr):
#   * A branch matching ^chore/(gardener|planner|predictor)- returns nothing —
#     even when the title or body mentions an issue (#N). The merge sweeper's
#     own chore rule then merges the PR as issue 0, closing nothing.
#   * The title fallback now accepts only a closing keyword (closes/fixes/
#     resolves, case-insensitive), same as the body rule — a bare #N in a
#     title no longer names an issue.
#   * The fix/issue-N branch rule and the body rule are unchanged.
#   * Both callers (pre-lock merge scan, stuck-PR scan) and the two existing
#     call-site chore rules are untouched.
#
# Acceptance (hermetic, in-process — no network, no live services): the
# function is extracted from the checkout with ac_extract_fn() and eval'd,
# then exercised directly against literal branch/title/body strings (it uses
# only grep/printf, so it runs clean in-process):
#   * AC1: branch chore/gardener-20261002-0600, title "chore: escalate #1620
#          starvation" -> prints nothing
#          (+ a chore/planner branch with "Closes #999" in the body -> nothing)
#   * AC2: branch fix/issue-12 -> prints 12
#   * AC3a: branch feature/x, title "Fixes #7" -> prints 7
#          AC3b: branch feature/x, title "touches #7" -> prints nothing
#   * AC4: branch feature/x, plain title, body "Closes #9" -> prints 9
#   * AC5: the fix/issue-N branch rule still wins over title/body mentions
#          and this test exits 0 and calls ac_pass.
#
# Read-only: no forge, no nomad, no agent. dev-poll.sh cannot be sourced
# (a top-level executable that would run the whole poll), so the function is
# extracted by header (ac_extract_fn()) exactly as issue-1130 does.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep

DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$DEV_POLL" "dev/dev-poll.sh is missing"

# ── Wiring: unchanged callers, intact call-site chore rules, new gate ───────
# Both merge scans still feed (branch, title, body) to extract_issue_from_pr
# — the two callers are unchanged by this fix.
grep -qF 'extract_issue_from_pr "$PL_PR_BRANCH" "$PL_PR_TITLE" "$PL_PR_BODY"' "$DEV_POLL" \
  || ac_fail "pre-lock merge scan must still call extract_issue_from_pr with (branch,title,body)"
grep -qF 'extract_issue_from_pr "$PR_BRANCH" "$PR_TITLE" "$PR_BODY"' "$DEV_POLL" \
  || ac_fail "stuck-PR scan must still call extract_issue_from_pr with (branch,title,body)"
# The two pre-existing call-site chore rules (turn an issue-less PR into issue
# 0, closing nothing) are intact.
grep -qF '"$PL_PR_BRANCH" =~ ^chore/(gardener|planner|predictor)-' "$DEV_POLL" \
  || ac_fail "pre-lock chore rule missing (it is what merges issue-less chore PRs)"
grep -qF '"$PR_BRANCH" =~ ^chore/(gardener|planner|predictor)-' "$DEV_POLL" \
  || ac_fail "stuck-PR chore rule missing (it is what merges issue-less chore PRs)"

# The merge sweeper (dev/merge-ready.sh) is the third linked-issue extraction
# site — it is what closed #1620 when chore PR #1669 merged. It must reuse
# extract_issue_from_pr (chore gate + closing-keyword title rule) rather than
# carry its own over-eager inline extraction (bare #N, last match, no chore gate).
MERGE_READY="$REPO_ROOT/dev/merge-ready.sh"
ac_assert_file "$MERGE_READY" "dev/merge-ready.sh is missing (merge sweeper)"
grep -qF 'extract_issue_from_pr' "$MERGE_READY" \
  || ac_fail "merge sweeper must use extract_issue_from_pr so a chore PR it merges never closes the issue it mentions (#1671)"
if grep -qF "grep -oP '#\K\d+' | tail -1" "$MERGE_READY"; then
  ac_fail "merge-ready.sh must not keep its old over-eager title rule (any bare #N, last match) (#1671)"
fi

# ── Extract the function under test ───────────────────────────────────────────
# ac_extract_fn() takes the column-0 `name() {` header to the next column-0
# closing brace; dev-poll.sh is a top-level executable so we never source it.
FN_SRC="$(ac_extract_fn extract_issue_from_pr "$DEV_POLL")"
[ -n "$FN_SRC" ] || ac_fail "could not extract extract_issue_from_pr() from dev-poll.sh"

# The extracted function carries the #1671 chore gate (a chore branch returns
# nothing before any title/body fallback can fire) and the new closing-keyword
# title rule, while the old over-eager title rule ("#\K\d+" with tail -1,
# matching a bare #N) is gone.
case "$FN_SRC" in
  *"chore/(gardener|planner|predictor)-"* ) ;;
  *) ac_fail "extracted function must contain the #1671 chore gate" ;;
esac
case "$FN_SRC" in
  *"closes|fixes|resolves"* ) ;;
  *) ac_fail "extracted function must use a closing-keyword title rule (#1671)" ;;
esac
if grep -q "grep -oP '#\\K\\d+' | tail -1" <<< "$FN_SRC"; then
  ac_fail "the old over-eager title rule (any #N, last match) must be gone"
fi

eval "$FN_SRC"

# ── AC1: chore/gardener branch mentioning #1620 in the title -> nothing ───────
ac_log "AC1: branch chore/gardener-20261002-0600, title 'chore: escalate #1620 starvation' -> nothing"
out="$(extract_issue_from_pr "chore/gardener-20261002-0600" "chore: escalate #1620 starvation" "")"
ac_assert_eq "$out" "" \
  "AC1: a chore/gardener branch must print nothing even when the title mentions an issue (got: '$out')"

# The chore gate must win over the body rule too (a gardener/planner/predictor
# PR may mention issues in its body and still close nothing).
out="$(extract_issue_from_pr "chore/planner-20261002-0601" "grooming" "Closes #999")"
ac_assert_eq "$out" "" \
  "AC1: a chore/planner branch must print nothing even when the body says 'Closes #N' (got: '$out')"

# ── AC2: fix/issue-N branch -> N (unchanged) ───────────────────────────────────
ac_log "AC2: branch fix/issue-12 -> 12"
out="$(extract_issue_from_pr "fix/issue-12" "" "")"
ac_assert_eq "$out" "12" "AC2: fix/issue-12 must print 12 (got: '$out')"

# ── AC3a: feature branch, title 'Fixes #7' (closing keyword) -> 7 ─────────────
ac_log "AC3a: branch feature/x, title 'Fixes #7' -> 7"
out="$(extract_issue_from_pr "feature/x" "Fixes #7" "")"
ac_assert_eq "$out" "7" "AC3a: a closing keyword in the title must print 7 (got: '$out')"

# ── AC3b: feature branch, title 'touches #7' (bare #N) -> nothing ─────────────
ac_log "AC3b: branch feature/x, title 'touches #7' -> nothing"
out="$(extract_issue_from_pr "feature/x" "touches #7" "")"
ac_assert_eq "$out" "" \
  "AC3b: a bare #N in the title must print nothing (got: '$out')"

# ── AC4: feature branch, plain title, body 'Closes #9' -> 9 ───────────────────
ac_log "AC4: branch feature/x, plain title, body 'Closes #9' -> 9"
out="$(extract_issue_from_pr "feature/x" "plain title" "Closes #9")"
ac_assert_eq "$out" "9" "AC4: a closing keyword in the body must print 9 (got: '$out')"

# ── AC5: the fix/issue-N branch rule still wins over title/body mentions ──────
ac_log "AC5: fix/issue-12 branch wins over 'Closes #999' title and 'Fixes #998' body"
out="$(extract_issue_from_pr "fix/issue-12" "Closes #999" "Fixes #998")"
ac_assert_eq "$out" "12" "the fix/issue-N branch rule must win over title/body (got: '$out')"

ac_log "all acceptance criteria met for issue 1671"
ac_pass
