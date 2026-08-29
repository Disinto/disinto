#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1089-reopened-pr-stale-reviews.sh
#
# Issue #1089: when a PR is closed and later reopened, Forgejo marks *every*
# review on the PR `stale: true` — including a review whose `commit_id`
# equals the current head (i.e. it still reflects the code being reviewed).
# dev-poll's `select(.stale == false)` filter then sees zero reviews, so the
# PR is simultaneously unpickable (no live REQUEST_CHANGES) and unmergeable
# (no live APPROVED): it falls into the "waiting" branch and, via WAITING_PRS,
# holds every other backlog issue for that agent forever.
#
# Evidence: PR #1079 (issue #1073), head 83329fc5, two REQUEST_CHANGES
# reviews, both stale, the newer one pinned to the head.
#
# Acceptance (self-contained, no live services needed):
#   1. A PR fixture shaped like #1079 (head H, one stale review at an old
#      commit, one stale review at H) must yield exactly 1 live
#      REQUEST_CHANGES review under the head-aware filter (pr_live_review
#      _count in lib/pr-lifecycle.sh), while the legacy stale-only filter
#      yields 0 — the bug.
#   2. The pickup decision dev-poll's backlog scan makes on that count is
#      therefore "pick up", not "waiting" — the wedge is broken.
#   3. No false positives: a stale review pinned to an OLD commit is not
#      live; missing/null commit_ids match nothing; an empty head SHA
#      matches nothing; a non-stale review is live regardless of commit.
#   4. commit_id matching is prefix-based in both directions (the API may
#      return shortened commit_ids or a shortened head).
#   5. dev-poll actually consumes the head-aware filter (wiring check).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

# lib/pr-lifecycle.sh logs via log() when defined — stub it (self-contained).
log() { :; }
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pr-lifecycle.sh"

# ── Fixture: the PR #1079 shape ──────────────────────────────────────────────
HEAD="83329fc55858ab12cd34ef678901234567890abcde"
OLD_COMMIT="1111122223333444455556666777788889990000"

# Both reviews went stale on close/reopen; only the newer one is pinned to
# the current head.
REVIEWS=$(jq -n --arg head "$HEAD" --arg old "$OLD_COMMIT" '
  [
    { state: "REQUEST_CHANGES", stale: true, commit_id: $old },
    { state: "REQUEST_CHANGES", stale: true, commit_id: $head },
    { state: "APPROVED",        stale: true, commit_id: $old }
  ]')

# ── 1. Legacy stale-only filter demonstrates the bug ────────────────────────

LEGACY_CHANGES=$(printf '%s' "$REVIEWS" | jq -r \
  '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length')
ac_assert_eq "$LEGACY_CHANGES" "0" \
  "fixture must reproduce the bug: legacy filter sees 0 REQUEST_CHANGES, got $LEGACY_CHANGES"

# ── 2. Head-aware filter: the at-head review is live → dev-poll picks up ────

LIVE_CHANGES=$(pr_live_review_count "$REVIEWS" "$HEAD" "REQUEST_CHANGES")
ac_assert_eq "$LIVE_CHANGES" "1" \
  "head-aware filter must count the at-head stale review as live (1), got $LIVE_CHANGES"

LIVE_APPROVE=$(pr_live_review_count "$REVIEWS" "$HEAD" "APPROVED")
ac_assert_eq "$LIVE_APPROVE" "0" \
  "the at-old-commit APPROVED must stay stale (0), got $LIVE_APPROVE"

# pr_live_reviews must return exactly the at-head review.
LIVE_JSON=$(pr_live_reviews "$REVIEWS" "$HEAD")
ac_assert_eq "$(printf '%s' "$LIVE_JSON" | jq 'length')" "1" \
  "pr_live_reviews must return exactly one live review, got $(printf '%s' "$LIVE_JSON" | jq 'length')"
ac_assert_eq "$(printf '%s' "$LIVE_JSON" | jq -r '.[0].commit_id')" "$HEAD" \
  "the live review must be the one pinned to the head"

# The pickup decision dev-poll's backlog scan makes on this count:
# HAS_CHANGES > 0 → READY_ISSUE (pick up), else the "waiting" branch.
if [ "$LIVE_CHANGES" -gt 0 ]; then
  DECISION="picked up"
else
  DECISION="waiting"
fi
ac_assert_eq "$DECISION" "picked up" \
  "dev-poll must pick the issue up instead of logging waiting"

# ── 3. No false positives ────────────────────────────────────────────────────

OLD_ONLY='[{"state":"REQUEST_CHANGES","stale":true,"commit_id":"1111122223333444455556666777788889990000"}]'
ac_assert_eq "$(pr_live_review_count "$OLD_ONLY" "$HEAD" "REQUEST_CHANGES")" "0" \
  "a stale review pinned to an old commit must not be treated as live"

NO_COMMIT_ID='[{"state":"REQUEST_CHANGES","stale":true}]'
ac_assert_eq "$(pr_live_review_count "$NO_COMMIT_ID" "$HEAD" "REQUEST_CHANGES")" "0" \
  "a stale review with a missing commit_id must not match the head"

NULL_COMMIT_ID='[{"state":"REQUEST_CHANGES","stale":true,"commit_id":null}]'
ac_assert_eq "$(pr_live_review_count "$NULL_COMMIT_ID" "$HEAD" "REQUEST_CHANGES")" "0" \
  "a stale review with a null commit_id must not match the head"

ac_assert_eq "$(pr_live_review_count "$REVIEWS" "" "REQUEST_CHANGES")" "0" \
  "an empty head SHA must match no review"

LIVE_NONSTALE='[{"state":"APPROVED","stale":false,"commit_id":"deadbeef"}]'
ac_assert_eq "$(pr_live_review_count "$LIVE_NONSTALE" "$HEAD" "APPROVED")" "1" \
  "a non-stale review must be live regardless of commit_id"

# Single-object (non-array) input is normalized to [.] — must not error.
SINGLE_OBJECT='{"state":"APPROVED","stale":false,"commit_id":"deadbeef"}'
ac_assert_eq "$(pr_live_reviews "$SINGLE_OBJECT" "$HEAD" | jq 'length')" "1" \
  "pr_live_reviews must accept a single review object, not just an array"

# ── 4. Prefix matching in both directions ───────────────────────────────────

SHORT_CID='[{"state":"REQUEST_CHANGES","stale":true,"commit_id":"83329fc5"}]'
ac_assert_eq "$(pr_live_review_count "$SHORT_CID" "$HEAD" "REQUEST_CHANGES")" "1" \
  "a shortened commit_id prefix of the full head must count as live"

FULL_CID='[{"state":"REQUEST_CHANGES","stale":true,"commit_id":"83329fc55858ab12cd34ef678901234567890abcde"}]'
ac_assert_eq "$(pr_live_review_count "$FULL_CID" "83329fc5" "REQUEST_CHANGES")" "1" \
  "a full commit_id must match a shortened head argument"

# ── 5. Wiring: dev-poll consumes the head-aware filter ──────────────────────

grep -q 'pr_live_review_count' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll does not use the head-aware live-review filter (pr_live_review_count)"
grep -q 'pr_live_reviews' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "lib/pr-lifecycle.sh is missing pr_live_reviews"

ac_pass
