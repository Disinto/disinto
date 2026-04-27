#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-850.sh — self-test for the acceptance-test convention
#
# Proves the runner + file convention are wired up end-to-end:
#   1. The convention doc exists and references this directory.
#   2. The runner exists and is executable.
#   3. The runner can discover and execute this very file (when invoked as the
#      outermost call — recursive invocations short-circuit via the
#      RUN_ACCEPTANCE_DEPTH guard set by the runner).
# =============================================================================
set -euo pipefail

# Run from the repo root so the relative paths below resolve regardless of
# where the runner was invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# 1. Convention doc.
[ -f docs/contributing/acceptance-tests.md ] \
  || { echo "FAIL: convention doc missing"; exit 1; }
grep -q "tests/acceptance" docs/contributing/acceptance-tests.md \
  || { echo "FAIL: convention doc does not mention tests/acceptance/"; exit 1; }

# 2. Runner exists and is executable.
[ -x tools/run-acceptance.sh ] \
  || { echo "FAIL: runner missing or not executable"; exit 1; }

# 3. Runner self-invocation. Only do this on the outermost call; the runner
#    bumps RUN_ACCEPTANCE_DEPTH each time it executes a test, so a re-entrant
#    invocation would loop forever otherwise.
if [ "${RUN_ACCEPTANCE_DEPTH:-0}" -le 1 ]; then
  issue_num="$(grep -oP 'issue-\K[0-9]+' <<< "$0" | head -1)"
  [ -n "$issue_num" ] \
    || { echo "FAIL: could not parse issue number from \$0=$0"; exit 1; }

  result="$(tools/run-acceptance.sh --format json "$issue_num")"
  echo "$result" | jq -e '.result == "PASS"' >/dev/null \
    || { echo "FAIL: self-invocation did not return PASS: $result"; exit 1; }
fi

echo PASS
