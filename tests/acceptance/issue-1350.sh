#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1350.sh — AGENTS.md says the tick, not interval organs
#
# Issue #1350 (docs): since #1333 the entrypoint no longer starts organs on
# staggered intervals — one loop iteration runs one oak/tick.sh per project,
# and the tick is the policy that picks (and starts) at most one organ.
# The root AGENTS.md still described the old policy.
#
# Read-only checks against the checkout's AGENTS.md:
#   1. contains oak/tick.sh
#   2. the architecture blurb ("What this repo is") says the entrypoint loop
#      calls oak/tick.sh per project per tick and scopes the start-only-on-pick
#      claim to the tick organs (the edge dispatcher runs its own loop and
#      launches the reproduce/triage sidecars — they are not tick starts)
#   3. the AD-001 row mentions the tick — planner/predictor/gardener/
#      supervisor are actions in oak/pack.example.toml, not a parallel cadence
#   4. does not describe ARCHITECT_INTERVAL / PLANNER_INTERVAL / "every 12h"
#      style fixed per-organ cadences as factory policy
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

# 2. The "What this repo is" blurb carries the tick fact.
ac_log "checking the architecture blurb names oak/tick.sh"
blurb="$(sed -n '/^## What this repo is/,/^## /p' "$MD")"
[ -n "$blurb" ] || ac_fail "'What this repo is' section not found in AGENTS.md"
grep -q "oak/tick.sh" <<< "$blurb" \
  || ac_fail "the 'What this repo is' blurb must say the entrypoint loop calls oak/tick.sh per project per tick (organs start only when the tick picks them)"
grep -qi "tick organs" <<< "$blurb" \
  || ac_fail "the blurb must scope the start-only-on-pick claim to the tick organs (the edge dispatcher runs its own loop and launches the reproduce/triage sidecars)"

# 3. The AD-001 row mentions the tick.
ac_log "checking the AD-001 row mentions the tick"
ad001="$(grep -E '^\| AD-001 \|' "$MD")"
[ -n "$ad001" ] || ac_fail "AD-001 row not found in AGENTS.md"
grep -qi "tick" <<< "$ad001" \
  || ac_fail "AD-001 must say the entrypoint loop calls oak/tick.sh (the tick picks organs)"

# 4. No fixed per-organ cadence is described as factory policy.
ac_log "checking no interval-organ cadence remains"
for needle in ARCHITECT_INTERVAL PLANNER_INTERVAL GARDENER_INTERVAL SUPERVISOR_INTERVAL predictor_interval "every 12h"; do
  ! grep -qi -e "$needle" "$MD" \
    || ac_fail "AGENTS.md must not describe '$needle' as factory policy (the tick is the policy, #1333)"
done

echo PASS
