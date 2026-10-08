#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1970.sh — AD-006 healer owner-notification exception
#
# Issue #1970: the AD-006 row still requires vault dispatch, and names the
# healer exception plus bin/notify-owner.sh. Section 5's exceptions list names
# bin/notify-owner.sh. No other AD row and no other part of section 5 names it.
#
# Read-only: greps AGENTS.md and formulas/review-pr.toml. No live box.
#
# Run via: tools/run-acceptance.sh 1970
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

AGENTS="$REPO_ROOT/AGENTS.md"
FORMULA="$REPO_ROOT/formulas/review-pr.toml"
ac_assert_file "$AGENTS" "AGENTS.md must exist"
ac_assert_file "$FORMULA" "formulas/review-pr.toml must exist"

ac_log "AD-006 still requires vault dispatch and names the healer exception"
ad006="$(grep -E '^\| AD-006 \|' "$AGENTS" || true)"
[ -n "$ad006" ] || ac_fail "AGENTS.md has no AD-006 row"
printf '%s\n' "$ad006" | grep -q 'External actions go through vault dispatch' \
  || ac_fail "AD-006 row must still say external actions go through vault dispatch"
printf '%s\n' "$ad006" | grep -q 'bin/notify-owner.sh' \
  || ac_fail "AD-006 row must name bin/notify-owner.sh"
printf '%s\n' "$ad006" | grep -q 'healer' \
  || ac_fail "AD-006 row must name the healer exception"
printf '%s\n' "$ad006" | grep -q 'Exception (owner, 2026-10-08)' \
  || ac_fail "AD-006 row must record the owner exception dated 2026-10-08"

ac_log "no other AD row names the healer exception"
other="$(grep -E '^\| AD-00[1-5] \|' "$AGENTS" || true)"
[ -n "$other" ] || ac_fail "AGENTS.md is missing AD-001 through AD-005"
if printf '%s\n' "$other" | grep -q 'notify-owner\|healer'; then
  ac_fail "no other AD row may name the healer exception or bin/notify-owner.sh"
fi

ac_log "section 5 exceptions list names bin/notify-owner.sh"
exceptions="$(grep -F '**Exceptions** (do NOT flag)' "$FORMULA" || true)"
[ -n "$exceptions" ] || ac_fail "section 5 exceptions list is missing"
printf '%s\n' "$exceptions" | grep -q 'bin/notify-owner.sh' \
  || ac_fail "section 5 exceptions list must name bin/notify-owner.sh"
printf '%s\n' "$exceptions" | grep -q 'bin/healer.sh' \
  || ac_fail "section 5 exceptions list must name calls from bin/healer.sh"

ac_log "no other part of section 5 names bin/notify-owner.sh"
section5="$(awk '/^## 5\. External action detection/,/^## 6\./' "$FORMULA")"
[ -n "$section5" ] || ac_fail "formulas/review-pr.toml has no section 5"
printf '%s\n' "$section5" | grep -q 'vault dispatch' \
  || ac_fail "section 5 must still require vault dispatch"
# Scanned directories stay the agent tree; the exception does not widen them.
printf '%s\n' "$section5" | grep -qF 'agent code (`dev/`, `action/`, `planner/`, `gardener/`, `supervisor/`, `predictor/`, `review/`, `formulas/`, `lib/`)' \
  || ac_fail "section 5 scanned directories must be unchanged"
rest="$(printf '%s\n' "$section5" | grep -vF '**Exceptions** (do NOT flag)' || true)"
if printf '%s\n' "$rest" | grep -q 'notify-owner'; then
  ac_fail "no other part of section 5 may name bin/notify-owner.sh"
fi

echo PASS
