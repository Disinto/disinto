#!/usr/bin/env bash
# .woodpecker/lib-pr-diff.sh — sourced by the PR-only CI scripts
# (check-defaults-golden.sh, acceptance-affected.sh).
#
# pr_diff_spec — print the git diff range of this pull request: <merge-base>...HEAD
# (the true PR diff). The CI clone is shallow, so the merge-base is usually
# missing at first: deepen the target branch by up to 300 commits until it
# appears (about a second). Only when that fails, fall back to
# origin/<target>..HEAD, a tree comparison that also lists files main changed
# since the PR branched; on PR #1763 that selected a test whose fix was on
# main but not on the branch. Returns 1 when origin/<target> cannot be fetched.
pr_diff_spec() {
  local target="${CI_COMMIT_TARGET_BRANCH:-main}" mb
  git fetch --no-tags origin "$target" 2>/dev/null || true
  git rev-parse --verify "origin/${target}" >/dev/null 2>&1 || return 1
  mb="$(git merge-base "origin/${target}" HEAD 2>/dev/null || true)"
  if [ -z "$mb" ]; then
    git fetch -q --no-tags --deepen=300 origin "$target" 2>/dev/null || true
    mb="$(git merge-base "origin/${target}" HEAD 2>/dev/null || true)"
  fi
  if [ -n "$mb" ]; then
    printf '%s...HEAD\n' "$mb"
  else
    printf 'origin/%s..HEAD\n' "$target"
  fi
}
