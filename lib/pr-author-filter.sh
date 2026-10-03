#!/usr/bin/env bash
# pr-author-filter.sh — limit a reviewer to PRs by some authors (#1690)
#
# Two reviewers can poll the same open PRs. Each container's review lock
# lives in its own /tmp, so nothing else stops both from posting a verdict
# on one head. Branch protection blocks on a rejected review, so a late
# REQUEST_CHANGES can stall a PR the other reviewer already approved.
#
# Each reviewer therefore keeps to its own authors:
#   REVIEW_ONLY_AUTHORS  space-separated logins this reviewer handles.
#                        Set and non-empty: any other login is refused.
#   REVIEW_SKIP_AUTHORS  space-separated logins left to another reviewer.
# Both unset (or empty): every author is allowed, as before this filter.
#
# pr_author_allowed LOGIN
#   return 1 when REVIEW_ONLY_AUTHORS is set and non-empty and does not
#   name LOGIN, or when REVIEW_SKIP_AUTHORS names LOGIN. Otherwise return 0.
#
# Hermetic: pure bash. No network, no forge, no agent.

set -euo pipefail

# _pr_author_named LOGIN LIST — 0 when LOGIN is a whole space-separated
# token of LIST. Substring matches do not count (dev-bot ≠ dev-bot-extra).
_pr_author_named() {
  local login="$1" list="$2" name
  local -a names=()
  # read -a collapses repeated IFS whitespace, so "a  b" is two tokens.
  read -r -a names <<< "$list"
  for name in "${names[@]+"${names[@]}"}"; do
    if [ "$name" = "$login" ]; then
      return 0
    fi
  done
  return 1
}

# pr_author_allowed LOGIN — 0 allow, 1 skip. See file header.
pr_author_allowed() {
  local login="${1:-}"
  local only="${REVIEW_ONLY_AUTHORS:-}"
  local skip="${REVIEW_SKIP_AUTHORS:-}"

  # ONLY set and non-empty, and LOGIN is not one of them: refuse.
  # An empty ONLY is treated as unset (every author still eligible here).
  if [ -n "$only" ] && ! _pr_author_named "$login" "$only"; then
    return 1
  fi

  # SKIP names LOGIN: refuse, even if ONLY also named it.
  if [ -n "$skip" ] && _pr_author_named "$login" "$skip"; then
    return 1
  fi

  return 0
}
