#!/usr/bin/env bash
# .woodpecker/acceptance-affected.sh — run the acceptance tests a PR can break.
#
# An acceptance test (tests/acceptance/issue-<N>.sh) runs once, after its own
# merge (.woodpecker/acceptance-tests.yml), and never again. A later PR that
# changes the code a test reads breaks it silently: on 2026-10-04 a run of
# all 178 tests on main found five broken that way (#1750-#1753, #1757).
#
# On a pull request this step runs every acceptance test that
#   1. the PR adds or changes,
#   2. names a path the PR changes (in its own text), or
#   3. sources a tests/lib/ helper that names such a path, or that the PR
#      changes (acceptance-helpers.sh, which every test sources, counts only
#      when the PR changes it),
# and fails if any of them fails. A test whose header has a line starting
# "# acceptance-ci: skip" needs what CI does not have (the live forge,
# nomad, the daemon's env) and is skipped here; it still runs after merge.
set -euo pipefail

[ "${CI_PIPELINE_EVENT:-}" = "pull_request" ] || { echo "skip: not a pull_request event (got ${CI_PIPELINE_EVENT:-unset})"; exit 0; }

# shellcheck source=lib-pr-diff.sh
. "$(dirname "$0")/lib-pr-diff.sh"
SPEC="$(pr_diff_spec)" || { echo "skip: origin/${CI_COMMIT_TARGET_BRANCH:-main} unavailable"; exit 0; }

# mentions PATH FILE... — print each FILE whose text names PATH. A path with
# a slash matches as a plain substring. A top-level name (AGENTS.md, VISION.md)
# must not be the tail of a longer path (dev/AGENTS.md): it matches only at
# the start, after a non-path character, after ROOT/ or ROOT}/ ($REPO_ROOT),
# or after ../.
mentions() {
  local p="$1" esc
  shift
  case "$p" in
    */*) grep -lF -- "$p" "$@" 2>/dev/null || true ;;
    *)
      esc="$(printf '%s' "$p" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
      grep -lE -- "(ROOT[}]?/|[.][.]/|^|[^A-Za-z0-9_./-])${esc}" "$@" 2>/dev/null || true
      ;;
  esac
}

SEL="$(mktemp)"; LOG="$(mktemp)"
trap 'rm -f "$SEL" "$LOG"' EXIT

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    tests/acceptance/issue-*.sh) printf '%s\n' "$f" >>"$SEL" ;;
  esac
  mentions "$f" tests/acceptance/issue-*.sh >>"$SEL"
  helpers="$(mentions "$f" tests/lib/*.sh)"
  case "$f" in tests/lib/*.sh) helpers="$helpers $f" ;; esac
  for h in $helpers; do
    [ "$h" = tests/lib/acceptance-helpers.sh ] && [ "$f" != "$h" ] && continue
    mentions "lib/$(basename "$h")" tests/acceptance/issue-*.sh >>"$SEL"
  done
done < <(git diff --name-only "$SPEC")

# ACCEPTANCE_AFFECTED_LIST=1: print the selection and stop (debugging).
if [ "${ACCEPTANCE_AFFECTED_LIST:-}" = 1 ]; then
  sort -u "$SEL"
  exit 0
fi

run=0; failed=0; skipped=0
while IFS= read -r t; do
  [ -f "$t" ] || continue
  if grep -q '^# acceptance-ci: skip' "$t"; then
    echo "SKIP $t ($(grep -m1 '^# acceptance-ci: skip' "$t" | sed 's/^# acceptance-ci: skip *//'))"
    skipped=$((skipped + 1))
    continue
  fi
  run=$((run + 1))
  rc=0; timeout 300 bash "$t" >"$LOG" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS $t"
  else
    failed=$((failed + 1))
    echo "FAIL $t (exit $rc), last lines:"
    tail -n 25 "$LOG" | sed 's/^/    /'
  fi
done < <(sort -u "$SEL")

echo "acceptance-affected: ${run} run, ${failed} failed, ${skipped} skipped (${SPEC})"
[ "$failed" -eq 0 ]
