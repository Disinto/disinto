#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1789.sh — threads GC job and the threads scan are gone
#
# Issue #1789: after chat and voice left the edge, the nightly
# edge-threads-gc job, bin/threads.sh, and the snapshot-inbox completed
# scan are dead. This script asserts the three acceptance criteria.
#
# Read-only: git ls-files, grep, and bash -n. It does not submit a job,
# write a store, or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1789.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd git grep bash

INBOX="$REPO_ROOT/bin/snapshot-inbox.sh"
ac_assert_file "$INBOX" "bin/snapshot-inbox.sh must still exist"

ac_log "criterion 1: git ls-files prints nothing for the deleted threads paths"
tracked="$(git -C "$REPO_ROOT" ls-files nomad/jobs/edge-threads-gc.hcl bin/threads.sh)"
if [ -n "$tracked" ]; then
  printf '%s\n' "$tracked" >&2
  ac_fail "edge-threads-gc.hcl or bin/threads.sh is still tracked"
fi

ac_log "criterion 2: snapshot-inbox.sh has no thread or THREADS token"
hits="$(grep -nE 'thread|THREADS' "$INBOX" || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" >&2
  ac_fail "bin/snapshot-inbox.sh still mentions threads"
fi

ac_log "criterion 3: snapshot-inbox.sh passes bash -n"
bash -n "$INBOX" || ac_fail "bash -n bin/snapshot-inbox.sh failed"

echo PASS
