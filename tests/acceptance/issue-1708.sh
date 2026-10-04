#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1708.sh
#
# Issue #1708: the header above no_push_outcome() names the tape count, not a
# branch count.
#
# Since #1646 the caller passes DEV_FAILED_ATTEMPTS — the count of this
# proposal's failed dev outcomes on the tape. The comment still described that
# argument as a 0-indexed count of existing fix/issue-N* branches. A no-push
# creates no branch, so an agent that aligned the caller with the comment
# would make the no_push_after_3_attempts cap never fire.
#
# Acceptance (read-only — the 30 lines above no_push_outcome(); no forge, no
# agent started):
#   1. those lines do not mention fix/issue-N* branches
#   2. those lines name DEV_FAILED_ATTEMPTS
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

fn_line="$(grep -n '^no_push_outcome() {' "$TARGET" | head -1 | cut -d: -f1)"
[ -n "$fn_line" ] || ac_fail "no_push_outcome() definition not found in dev/dev-agent.sh"

start=$((fn_line - 30))
[ "$start" -ge 1 ] || ac_fail "no_push_outcome() is fewer than 30 lines into the file (line $fn_line)"

header="$(sed -n "${start},$((fn_line - 1))p" "$TARGET")"
[ -n "$header" ] || ac_fail "could not read the 30 lines above no_push_outcome()"

ac_log "AC 1: the 30 lines above no_push_outcome() do not mention fix/issue-N* branches"
if printf '%s\n' "$header" | grep -F 'fix/issue-N*' >/dev/null; then
  ac_fail "comment above no_push_outcome() still mentions fix/issue-N* branches"
fi

ac_log "AC 2: those lines name DEV_FAILED_ATTEMPTS"
if ! printf '%s\n' "$header" | grep -F 'DEV_FAILED_ATTEMPTS' >/dev/null; then
  ac_fail "comment above no_push_outcome() does not name DEV_FAILED_ATTEMPTS"
fi

ac_pass
