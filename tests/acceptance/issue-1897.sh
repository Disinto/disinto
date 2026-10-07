#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1897.sh
#
# Issue #1897: issue-writing names a model acceptance test that exists.
# docs/design/notes/issue-writing.md must not cite the deleted
# tests/acceptance/issue-1598.sh, and must name tests/acceptance/issue-1216.sh,
# which exists and uses both ac_extract_fn and ac_write_curl_stub.
#
# This test is read-only: it greps the note and the model test.
#
# Run via: tools/run-acceptance.sh 1897
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

NOTE="$REPO_ROOT/docs/design/notes/issue-writing.md"
MODEL="$REPO_ROOT/tests/acceptance/issue-1216.sh"

ac_assert_file "$NOTE" "issue-writing note missing: $NOTE"
ac_assert_file "$MODEL" "model acceptance test missing: $MODEL"

ac_log "issue-writing.md no longer cites the deleted issue-1598.sh"
# grep -c exits 1 when the count is 0; the script is set -e, so tolerate that.
stale="$(grep -c 'issue-1598' "$NOTE" || true)"
[ "$stale" = 0 ] \
  || ac_fail "issue-writing.md still cites issue-1598 (count: ${stale})"

ac_log "issue-writing.md names tests/acceptance/issue-1216.sh"
named="$(grep -c 'tests/acceptance/issue-1216.sh' "$NOTE" || true)"
[ "$named" -ge 1 ] \
  || ac_fail "issue-writing.md does not name tests/acceptance/issue-1216.sh"

ac_log "issue-1216.sh uses both ac_extract_fn and ac_write_curl_stub"
extract="$(grep -c 'ac_extract_fn' "$MODEL" || true)"
stub="$(grep -c 'ac_write_curl_stub' "$MODEL" || true)"
if [ "$extract" -lt 1 ] || [ "$stub" -lt 1 ]; then
  ac_fail "issue-1216.sh must use both helpers (ac_extract_fn=${extract}, ac_write_curl_stub=${stub})"
fi

ac_pass "issue #1897: issue-writing names issue-1216.sh, which uses both stub helpers"
