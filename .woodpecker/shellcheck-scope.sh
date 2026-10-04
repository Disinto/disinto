#!/usr/bin/env bash
# .woodpecker/shellcheck-scope.sh — the shellcheck step of ci.yml.
#
# On a pull request, lint only the .sh files the PR adds or changes; on any
# other event (push to main), lint every .sh file. Linting all of them took
# 16-18 of the ~28 minutes a PR spent in CI (pipelines 3617, 3623,
# 2026-10-04), and an unchanged file's result does not change. The push to
# main still lints everything, as a backstop for effects across files.
set -euo pipefail

if [ "${CI_PIPELINE_EVENT:-}" = "pull_request" ]; then
  # shellcheck source=lib-pr-diff.sh
  . "$(dirname "$0")/lib-pr-diff.sh"
  if SPEC="$(pr_diff_spec)"; then
    mapfile -t files < <(git diff --name-only --diff-filter=d "$SPEC" -- '*.sh')
    echo "shellcheck: ${#files[@]} changed .sh file(s) in ${SPEC}"
    [ "${#files[@]}" -gt 0 ] || exit 0
    exec shellcheck --severity=warning "${files[@]}"
  fi
  echo "shellcheck: PR base unavailable, linting every .sh file"
fi

find . -name "*.sh" -not -path "./.git/*" -print0 | xargs -0 -r shellcheck --severity=warning
