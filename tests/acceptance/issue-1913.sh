#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1913.sh
#
# Issue #1913: organs.md records merging the pitch as the decision.
# Decision 3 must not still say an approving review on the ops PR is the
# gate, and must say merging the pitch PR is the decision.
#
# This test is read-only: it greps the design note. It does not edit the
# note and does not talk to forge or nomad.
#
# Run via: tools/run-acceptance.sh 1913
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep awk

NOTE="$REPO_ROOT/docs/design/notes/organs.md"
ac_assert_file "$NOTE" "organs note missing: $NOTE"

ac_log "organs.md no longer says an approving review on the ops PR is the decision"
# grep -c exits 1 when the count is 0; the script is set -e, so tolerate that.
stale="$(grep -c 'an approving review on the ops PR' "$NOTE" || true)"
ac_assert_eq "$stale" "0" \
  "organs.md still says an approving review on the ops PR (count: ${stale})"

ac_log "decision 3 says merging the pitch PR is the decision"
decision3="$(awk '
  /^3\. \*\*Approval:\*\*/ { capture = 1 }
  capture && /^4\. / { exit }
  capture { print }
' "$NOTE")"
[ -n "$decision3" ] || ac_fail "decision 3 (Approval) not found in organs.md"
printf '%s\n' "$decision3" | grep -q 'merging the pitch PR is the decision' \
  || ac_fail "decision 3 does not contain: merging the pitch PR is the decision"

ac_pass "issue #1913: organs.md records merging the pitch as the decision"
