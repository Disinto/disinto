#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1787.sh — the voice bridge, UI, and docs are deleted
#
# Issue #1787: nothing tracked remains under docker/voice or docs/voice, and
# the live voice/nomad acceptance scripts (issue-868, issue-882) are gone.
# site/compass.md and docs/AGENTS.md no longer mention voice.
#
# Read-only: git ls-files and grep. Does not build an image or start a process.
#
# Acceptance: `bash tests/acceptance/issue-1787.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd git grep

ac_assert_file "$REPO_ROOT/site/compass.md" "site/compass.md must exist"
ac_assert_file "$REPO_ROOT/docs/AGENTS.md" "docs/AGENTS.md must exist"

ac_log "checking git ls-files prints nothing for the deleted voice paths"
tracked="$(
  cd "$REPO_ROOT" &&
    git ls-files docker/voice docs/voice \
      tests/acceptance/issue-868.sh tests/acceptance/issue-882.sh
)"
if [ -n "$tracked" ]; then
  printf '%s\n' "$tracked"
  ac_fail "voice paths are still tracked"
fi

ac_log "checking site/compass.md and docs/AGENTS.md do not mention voice"
if grep -n voice "$REPO_ROOT/site/compass.md" "$REPO_ROOT/docs/AGENTS.md"; then
  ac_fail "site/compass.md or docs/AGENTS.md still mentions voice"
fi

echo PASS
