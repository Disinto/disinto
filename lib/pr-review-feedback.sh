#!/usr/bin/env bash
# =============================================================================
# lib/pr-review-feedback.sh — the review a restarted attempt must address
# (issue #1688)
#
# When dev-poll restarts an attempt on an open PR (e.g. after a ci_timeout),
# dev-agent.sh runs with the "CRASH RECOVERY" prompt. That prompt says
# "Address any pending review comments or CI failures" but carried no review
# text — the in-walk pr_poll_review() in lib/pr-lifecycle.sh does the comment
# lookup, a restart does not. The #1672 restart (2026-10-02) spent ~45 min
# hunting the review (reading the Forge API docs for a comment endpoint) and
# pushed without the doc change the review asked for, costing an extra review
# round. This lib hands the review text to the recovery prompt so the agent
# addresses it on its first try.
#
# Sourced from:
#   source "$(dirname "$0")/../lib/pr-review-feedback.sh"
#
# Requires (all available to any caller that also uses the PR walk):
#   forge_api() / forge_api_all() from lib/env.sh, and jq.
#
# The function is a pure reader, must stay silent under `set -euo pipefail`
# when sourced by a top-level agent script, and is written from scratch
# (not copied from pr_poll_review()) — CI's duplicate-detection rejects
# copied windows.
#
# Function:
#   pr_review_feedback PR_NUMBER
#     -> prints the body of the most recent review-bot comment on the PR whose
#        body carries the marker `<!-- reviewed: <head sha> -->` for the PR's
#        current head SHA — and only when that body requests changes
#        (`**REQUEST_CHANGES**`). An APPROVE/DISCUSS re-review, an absent
#        marker, a missing head SHA, or any API fault => empty output.
#     -> Always rc 0; the caller decides what empty means.
# =============================================================================
set -euo pipefail

# pr_review_feedback PR_NUMBER
# Prints the review-bot comment body for the PR's current head when it is a
# change request; prints nothing otherwise. Always rc 0.
pr_review_feedback() {
  local pr_num="${1:-}"
  local pr_json head_sha comments body

  # Head SHA of the PR (field .head.sha). A fault here leaves nothing to
  # address; the marker lookup below is skipped.
  pr_json=$(forge_api GET "/pulls/${pr_num:-}") || pr_json=""
  head_sha=$(printf '%s' "$pr_json" | jq -r '.head.sha // empty') || head_sha=""
  [ -n "$head_sha" ] || return 0

  # All comments on the PR, paginated into one JSON array. A fault here
  # likewise means nothing to address.
  comments=$(forge_api_all "/issues/${pr_num}/comments") || comments=""
  [ -n "$comments" ] || return 0

  # The most recent comment whose body carries the review-bot marker for the
  # current head. The marker is the literal line the review bot writes on each
  # review (lib/... review/review-pr.sh): `<!-- reviewed: <sha> -->`.
  body=$(printf '%s' "$comments" | jq -r --arg sha "$head_sha" '
    [ .[] | select((.body // "") | contains("<!-- reviewed: " + $sha + " -->")) ]
    | last
    | (.body // "")
  ') || return 0
  [ -n "$body" ] || return 0

  # Only a change request carries feedback the restarted attempt must address;
  # an APPROVE or DISCUSS re-review means no change is required.
  if printf '%s' "$body" | grep -qF '**REQUEST_CHANGES**'; then
    printf '%s\n' "$body"
  fi

  return 0
}
