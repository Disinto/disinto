#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1688.sh
#
# Issue #1688: feat(dev): a restarted attempt is given the review it must
# address.
#
# When dev-poll restarts an attempt on an open PR (e.g. after a ci_timeout),
# dev-agent.sh runs with the "CRASH RECOVERY" prompt, which says "Address any
# pending review comments or CI failures" but carried no review text — the
# in-walk pr_poll_review() in lib/pr-lifecycle.sh does the comment lookup, a
# restart did not. The #1672 restart (2026-10-02) spent ~45 min hunting the
# review and pushed without the doc change it asked for.
#
# Hermetic: no network — forge_api() and forge_api_all() are stubbed as shell
# functions; fixtures are shaped like the review bot's comments (see
# review/review-pr.sh for the real shape: header + `<!-- reviewed: <sha> -->`
# marker + `**VERDICT** — reason` verdict line).
#
# Acceptance:
#   1. head sha `abc`; a REQUEST_CHANGES review marked `old`, then a
#      REQUEST_CHANGES review marked `abc` with body X -> X is printed
#   2. the latest review marked `abc` says APPROVE -> nothing printed
#   3. no comment marked `abc` -> nothing printed, rc 0
#   4. forge_api failing -> nothing printed, rc 0
#   5. dev-agent.sh sources lib/pr-review-feedback.sh and the recovery prompt
#      calls pr_review_feedback "$PR_NUMBER" exactly once
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd grep

# lib/pr-review-feedback.sh is a pure reader; it needs no env.sh preconditions,
# and its two forge calls are stubbed below, so it can be sourced directly.
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pr-review-feedback.sh"

PR_NUM=1
# PR whose head sha the reviews must match to count as "current".
FORGE_HEAD_JSON='{"state":"open","head":{"ref":"fix/issue-1","sha":"abc"}}'
FORGE_COMMENTS_JSON='[]'
FORGE_API_FAIL=0
FORGE_API_ALL_FAIL=0

# Stubs for the two Forge calls the helper makes:
#   - forge_api GET /pulls/<N>           -> PR JSON (we return the head-sha fixture)
#   - forge_api_all /issues/<N>/comments -> all review comments
# FORGE_API_FAIL simulates a forge outage on the head fetch; FORGE_API_ALL_FAIL
# additionally simulates a comments-fetch failure.
forge_api() {
  # stub arg 1 is the HTTP method (GET); we only care about the path.
  local path="${2:-}"
  [ "$FORGE_API_FAIL" = "1" ] && return 1
  case "$path" in
    /pulls/*) printf '%s' "$FORGE_HEAD_JSON" ;;
    *) printf '%s' '{}' ;;
  esac
}

forge_api_all() {
  local path="${1:-}"
  [ "$FORGE_API_FAIL" = "1" ] && return 1
  [ "$FORGE_API_ALL_FAIL" = "1" ] && return 1
  case "$path" in
    /issues/*) printf '%s' "$FORGE_COMMENTS_JSON" ;;
    *) printf '[]' ;;
  esac
}

# The exact body the review bot posts for a given (sha, verdict, reason) — the
# single source of truth for both the fixtures and the expected output.
review_body() {
  printf '%b' "## AI\n<!-- reviewed: ${1} -->\n\nchange review notes\n\n### Verdict\n**${2}** — ${3}\n\n---\n*Reviewed at ${1}*"
}

# One review-bot comment object in Forgejo shape.
review_comment() {
  local body
  body="$(review_body "$1" "$2" "$3")"
  jq -cn --arg body "$body" '{id:1,body:$body}'
}

# Forgejo comment array from one-or-more single-line JSON comment objects ($@).
comments_json() {
  printf '%s\n' "$@" | jq -s -c '.'
}

# ── Case 1: a REQUEST_CHANGES review pinned to the old head, then one pinned
# to the current head (abc) -> the current-head review's body (X) is printed. ─
OLD_OBJ=$(review_comment old REQUEST_CHANGES "old doc missing")
NEW_OBJ=$(review_comment abc REQUEST_CHANGES "add missing docs entry")
FORGE_COMMENTS_JSON=$(comments_json "$OLD_OBJ" "$NEW_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
ac_assert_eq "$OUT" "$(review_body abc REQUEST_CHANGES "add missing docs entry")" \
  "a REQUEST_CHANGES review marked with the current head sha must be the feedback"

# ── Case 2: the latest abc review is APPROVE -> nothing to address. ───────────
APPROVE_OBJ=$(review_comment abc APPROVE "looks good")
FORGE_COMMENTS_JSON=$(comments_json "$APPROVE_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
ac_assert_eq "$OUT" "" \
  "an APPROVE re-review of the current head must print no feedback"

# ── Case 3: no comment carries the abc marker -> nothing, rc 0. ──────────────
OLD_ONLY_OBJ=$(review_comment old REQUEST_CHANGES "old doc")
FORGE_COMMENTS_JSON=$(comments_json "$OLD_ONLY_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
rc=$?
ac_assert_eq "$OUT" "" "no review for the current head must print nothing"
ac_assert_eq "$rc" "0" "no review for the current head must still return rc 0"

# ── Case 4: forge_api failing (outage on the head fetch) -> nothing, rc 0. ────
FORGE_API_FAIL=1
DOCS_OBJ=$(review_comment abc REQUEST_CHANGES "docs")
FORGE_COMMENTS_JSON=$(comments_json "$DOCS_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
rc=$?
ac_assert_eq "$OUT" "" "a forge_api failure must print nothing"
ac_assert_eq "$rc" "0" "a forge_api failure must return rc 0"

# ── Case 5: comments fetch failing (outage after the head is known) -> rc 0. ─
FORGE_API_FAIL=0
FORGE_API_ALL_FAIL=1
FORGE_COMMENTS_JSON=$(comments_json "$DOCS_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
rc=$?
ac_assert_eq "$OUT" "" "a forge_api_all failure must print nothing"
ac_assert_eq "$rc" "0" "a forge_api_all failure must return rc 0"

# ── Case 6: DISCUSS re-review (not a change request) -> nothing to address. ───
FORGE_API_ALL_FAIL=0
DISCUSS_OBJ=$(review_comment abc DISCUSS "clarify scope")
FORGE_COMMENTS_JSON=$(comments_json "$DISCUSS_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
ac_assert_eq "$OUT" "" \
  "a DISCUSS re-review of the current head must print no feedback"

# ── Case 7: two abc REQUEST_CHANGES reviews -> the latest (last) is feedback. ─
A_OBJ=$(review_comment abc REQUEST_CHANGES "first round notes")
B_OBJ=$(review_comment abc REQUEST_CHANGES "second round notes")
FORGE_COMMENTS_JSON=$(comments_json "$A_OBJ" "$B_OBJ")
OUT=$(pr_review_feedback "$PR_NUM")
ac_assert_eq "$OUT" "$(review_body abc REQUEST_CHANGES "second round notes")" \
  "when several current-head reviews exist, the latest (last) one must be the feedback"

# ── Case 8: wiring — dev-agent.sh sources the lib and the recovery prompt
# calls pr_review_feedback "$PR_NUMBER" exactly once. ─────────────────────────
grep -q 'source "$(dirname "$0")/../lib/pr-review-feedback.sh"' \
  "$REPO_ROOT/dev/dev-agent.sh" \
  || ac_fail "dev-agent.sh must source lib/pr-review-feedback.sh"
COUNT=$(grep -c 'pr_review_feedback "$PR_NUMBER"' "$REPO_ROOT/dev/dev-agent.sh")
ac_assert_eq "$COUNT" "1" \
  "the recovery prompt must call pr_review_feedback \"\${PR_NUMBER}\" exactly once (got $COUNT)"

# ── Case 9: the capture and the prompt section are present. ──────────────────
grep -q 'REVIEW_FEEDBACK=.*pr_review_feedback' "$REPO_ROOT/dev/dev-agent.sh" \
  || ac_fail "dev-agent.sh must capture pr_review_feedback into REVIEW_FEEDBACK"
grep -q '### Review to address (the latest review of the current head)' \
  "$REPO_ROOT/dev/dev-agent.sh" \
  || ac_fail "the recovery prompt must reference the review-to-address section"

ac_pass
