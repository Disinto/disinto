#!/usr/bin/env bash
# .woodpecker/lib-pr-diff.sh — sourced by the PR-only CI scripts
# (check-defaults-golden.sh, acceptance-affected.sh).
#
# pr_diff_spec — print the git diff range of this pull request: <merge-base>...HEAD
# (the true PR diff) when history allows. The shallow CI clone often has no
# shared history, so it falls back to origin/<target>..HEAD (a tree
# comparison, which can also list files main changed since the PR branched).
# Returns 1 when origin/<target> cannot be fetched.
pr_diff_spec() {
  local target="${CI_COMMIT_TARGET_BRANCH:-main}" mb
  git fetch --no-tags origin "$target" 2>/dev/null || true
  git rev-parse --verify "origin/${target}" >/dev/null 2>&1 || return 1
  mb="$(git merge-base "origin/${target}" HEAD 2>/dev/null || true)"
  if [ -n "$mb" ]; then
    printf '%s...HEAD\n' "$mb"
  else
    printf 'origin/%s..HEAD\n' "$target"
  fi
}
