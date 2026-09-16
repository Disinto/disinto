#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1350.sh — AGENTS.md says cadence scheduler + dry-run
# shadow tick
#
# Issue #1350 (docs) originally made AGENTS.md match the tick-only policy
# (#1333). #1388 restored the per-organ cadence scheduler and demoted the
# oak tick to a dry-run shadow (OAK_DRY_RUN=1 — senses, picks, logs, never
# execs an organ); the tick learner retires in #1390. This test now pins the
# post-#1388 wording.
#
# Read-only checks against the checkout's AGENTS.md:
#   1. contains oak/tick.sh
#   2. the architecture blurb ("What this repo is") says the entrypoint loop
#      paces the organs on their own intervals AND names oak/tick.sh as a
#      dry-run shadow with OAK_DRY_RUN=1
#   3. the blurb no longer claims organs "start only when the tick picks
#      them" (the pre-#1388 wording)
#   4. the AD-001 row mentions the tick as a dry-run shadow, and keeps the
#      "not PR-based actions" fact
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_require_cmd grep

MD="$REPO_ROOT/AGENTS.md"
ac_assert_file "$MD" "AGENTS.md must exist in the checkout"

# 1. The doc points at the tick.
ac_log "checking AGENTS.md contains oak/tick.sh"
grep -q "oak/tick.sh" "$MD" \
  || ac_fail "AGENTS.md must contain oak/tick.sh"

# 2. The "What this repo is" blurb carries the post-#1388 facts: per-organ
#    intervals + the tick as a dry-run shadow with OAK_DRY_RUN=1.
ac_log "checking the architecture blurb names the cadence scheduler and the shadow tick"
blurb="$(sed -n '/^## What this repo is/,/^## /p' "$MD")"
[ -n "$blurb" ] || ac_fail "'What this repo is' section not found in AGENTS.md"
grep -q "oak/tick.sh" <<< "$blurb" \
  || ac_fail "the 'What this repo is' blurb must name oak/tick.sh"
grep -q "OAK_DRY_RUN=1" <<< "$blurb" \
  || ac_fail "the blurb must say the tick runs as a dry-run shadow (OAK_DRY_RUN=1)"
grep -qi "dry-run" <<< "$blurb" \
  || ac_fail "the blurb must call the tick a dry-run shadow"
for cadence in "every 20 min" "every 12h" "daily"; do
  grep -qi "$cadence" <<< "$blurb" \
    || ac_fail "the blurb must describe the per-organ intervals (expected '$cadence')"
done

# 3. The pre-#1388 start-only-on-pick wording is gone.
ac_log "checking the old start-only-on-pick wording is gone"
! grep -qi "start only when the tick picks" "$MD" \
  || ac_fail "AGENTS.md must not claim organs start only when the tick picks them (the cadence scheduler was restored by #1388)"

# 4. The AD-001 row mentions the tick as a dry-run shadow and keeps the
#    polling-loop / not-PR-based-actions fact.
ac_log "checking the AD-001 row"
ad001="$(grep -E '^\| AD-001 \|' "$MD")"
[ -n "$ad001" ] || ac_fail "AD-001 row not found in AGENTS.md"
grep -qi "tick" <<< "$ad001" \
  || ac_fail "AD-001 must mention the oak tick"
grep -qi "dry-run" <<< "$ad001" \
  || ac_fail "AD-001 must say the tick runs as a dry-run shadow"
grep -qi "PR-based" <<< "$ad001" \
  || ac_fail "AD-001 must keep the 'not PR-based actions' fact"

echo PASS
