#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1799.sh — edge CI triggers no longer list chat, voice
# or threads paths
#
# Issue #1799: build-edge.yml and the acceptance-tests.yml redeploy pattern
# stop naming the paths wave 2 deleted, and the docs stop saying tests query
# chat/voice or that a smoke check covers chat login.
#
# Read-only: grep. No live box.
#
# Acceptance: `bash tests/acceptance/issue-1799.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

ac_assert_file .woodpecker/build-edge.yml ".woodpecker/build-edge.yml must exist"
ac_assert_file .woodpecker/acceptance-tests.yml ".woodpecker/acceptance-tests.yml must exist"
ac_assert_file docs/contributing/acceptance-tests.md "docs/contributing/acceptance-tests.md must exist"
ac_assert_file tests/acceptance/README.md "tests/acceptance/README.md must exist"
ac_assert_file docs/nomad-cutover-runbook.md "docs/nomad-cutover-runbook.md must exist"

ac_log "checking build-edge.yml does not list voice, chat, or threads"
if grep -nE 'voice|chat|threads' .woodpecker/build-edge.yml; then
  ac_fail "build-edge.yml still lists voice, chat, or threads"
fi

ac_log "checking acceptance-tests.yml does not list voice, chat, or threads.sh"
if grep -nE 'voice|chat|threads\.sh' .woodpecker/acceptance-tests.yml; then
  ac_fail "acceptance-tests.yml still lists voice, chat, or threads.sh"
fi

ac_log "checking the redeploy pattern names only edge, snapshot, and edge.hcl"
count="$(grep -cF '^(docker/edge/|bin/snapshot-|nomad/jobs/edge' .woodpecker/acceptance-tests.yml || true)"
if [ "$count" != "1" ]; then
  ac_fail "expected the edge redeploy pattern once, got ${count}"
fi

ac_log "checking the docs no longer mention chat or voice"
if grep -niE 'chat|voice' \
  docs/contributing/acceptance-tests.md \
  tests/acceptance/README.md \
  docs/nomad-cutover-runbook.md; then
  ac_fail "docs still mention chat or voice"
fi

echo PASS
