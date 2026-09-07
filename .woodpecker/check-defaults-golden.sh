#!/usr/bin/env bash
# .woodpecker/check-defaults-golden.sh — #1261: a PR that moves a known
# default must update its golden tests in the same commit.
#
# The goldens pin the old values, so a move without a test update breaks CI
# only after the push — twice in two days (#1252: review 2400->3600 vs
# tests/acceptance/issue-1171; #1260: dsh 163840->100000 vs
# tests/hire-an-agent-harness.bats), each costing a full CI+review cycle.
# This step fails the PR early, naming the golden files to update.
#
# Mapping lines: "CONSTANTS | watched source paths | golden test files".
# A constant counts as moved when any line added/removed under a watched path
# names it (word-bounded: REVIEW_CLAUDE_TIMEOUT is not CLAUDE_TIMEOUT).
# Touching ANY listed golden file satisfies the check. A comment-only edit
# under a watched path also fires — intentional: updating or rewording the
# golden is cheaper than a post-push CI break.
set -euo pipefail

[ "${CI_PIPELINE_EVENT:-}" = "pull_request" ] || { echo "skip: not a pull_request event (got ${CI_PIPELINE_EVENT:-unset})"; exit 0; }

TARGET="${CI_COMMIT_TARGET_BRANCH:-main}"
git fetch --no-tags origin "$TARGET" 2>/dev/null || true
BASE="origin/${TARGET}"
git rev-parse --verify "$BASE" >/dev/null 2>&1 || { echo "skip: ${BASE} unavailable"; exit 0; }

# 3-dot (true PR diff) when history allows; the shallow CI clone has no
# shared history, so fall back to a 2-dot tree comparison.
MB="$(git merge-base "$BASE" HEAD 2>/dev/null || true)"
SPEC="$MB...HEAD"; [ -n "$MB" ] || SPEC="$BASE..HEAD"

CHANGED="$(git diff --name-only "$SPEC")"

MAP='DSH_CONTEXT_WINDOW|lib/ docker/ nomad/jobs/|tests/hire-an-agent-harness.bats
CLAUDE_TIMEOUT|lib/ docker/ review/ docker-compose.yml nomad/jobs/|tests/hire-an-agent-nomad.bats tests/fixtures/hire-an-agent-harness/jobspec-default.hcl tests/fixtures/hire-an-agent-harness/compose-default.yml tests/acceptance/issue-1171-review-env-overrides.sh
MAX_DIFF DIFF_THRESHOLD DIGEST_CAP|review/|tests/acceptance/issue-1257-re-review-digest.sh'

FAIL=0
while IFS='|' read -r NAMES WATCHED GOLDENS; do
  for C in $NAMES; do
    RE="(^|[^A-Za-z0-9_])${C}([^A-Za-z0-9_]|$)"
    # shellcheck disable=SC2086  # WATCHED is an intentional unquoted pathspec list
    MOVED="$(git diff "$SPEC" -- $WATCHED | grep -E '^[+-]' | grep -vE '^[+-]{3} (a/|b/|/dev)' | grep -E "$RE" || true)"
    [ -n "$MOVED" ] || continue
    OK=0
    for G in $GOLDENS; do
      printf '%s\n' "$CHANGED" | grep -qx -- "$G" && OK=1
    done
    if [ "$OK" = 1 ]; then continue; fi
    FAIL=1
    {
      echo "::error:: ${C} moved in this PR, but its golden tests were not updated"
      echo "  changed lines under watched paths (first 3):"
      printf '%s\n' "$MOVED" | head -n 3 | sed 's/^/    /'
      echo "  the goldens pin the old value — CI breaks post-push without them (#1252, #1260)."
      echo "  update in the same PR: $(printf '%s' "$GOLDENS" | tr ' ' '  ' | sed 's/  /, /g')"
      echo "  if no test actually pins this default, say so in the PR description."
    } >&2
  done
done <<<"$MAP"

if [ "$FAIL" = 0 ]; then
  echo "ok: moved defaults are accompanied by golden test updates"
fi
exit "$FAIL"
