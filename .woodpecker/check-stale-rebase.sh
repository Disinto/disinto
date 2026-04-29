#!/usr/bin/env bash
# .woodpecker/check-stale-rebase.sh — CI guard for the stale-base regression
# detector (#896). Belt-and-braces sibling to the review-bot pre-check in
# review/review-pr.sh.
#
# Runs only on pull_request events. Exits 0 if no regression is detected,
# 1 if any file would silently revert upstream changes after merge.
#
# Required environment (set by Woodpecker):
#   CI_COMMIT_REF           — refs/pull/<n>/head for pull_request events
#   CI_COMMIT_SHA           — PR head commit SHA
#   CI_COMMIT_TARGET_BRANCH — branch the PR is targeting (e.g. main)
set -euo pipefail

# Shortcut: this script only runs in pull_request context. If invoked on a
# push, do nothing (the check is meaningful only when comparing PR head to
# the target branch).
if [ "${CI_PIPELINE_EVENT:-}" != "pull_request" ]; then
  echo "skip: not a pull_request event (got ${CI_PIPELINE_EVENT:-unset})"
  exit 0
fi

# shellcheck source=../lib/stale-base-check.sh
source "$(dirname "$0")/../lib/stale-base-check.sh"

PR_HEAD="${CI_COMMIT_SHA:-HEAD}"
TARGET="${CI_COMMIT_TARGET_BRANCH:-main}"

# Make sure we have the target branch fetched. The default Woodpecker clone
# is shallow at depth 1; deepen so merge-base resolves correctly.
git fetch --no-tags origin "$TARGET" 2>/dev/null || true

# Ensure the PR head is reachable as a local ref (depth-1 clone may not
# have history). Best-effort — the check exits 0 silently if refs missing.
git fetch --no-tags origin "$PR_HEAD" 2>/dev/null || true

TARGET_REF="origin/${TARGET}"
git rev-parse --verify "$TARGET_REF" >/dev/null 2>&1 || {
  echo "skip: target ref ${TARGET_REF} unavailable"
  exit 0
}

OUT=$(stale_base_check "$PR_HEAD" "$TARGET_REF")
if [ -z "$OUT" ]; then
  echo "ok: no stale-base regression detected"
  exit 0
fi

echo "::error:: stale-base regression detected — this PR's merge would"
echo "silently revert upstream changes that landed on ${TARGET} since the"
echo "PR's merge-base. Rebase on ${TARGET} and re-resolve any conflicts so"
echo "the upstream changes are preserved."
echo
echo "Affected files:"
stale_base_check_format "$OUT"
exit 1
