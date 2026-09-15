#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1351.sh — site docs say the oak tick is the cadence
#
# Issue #1351 (docs): the live loop is one oak/tick.sh per POLL_INTERVAL
# (default 5 min); the tick picks (and starts) at most one organ, legal
# actions come from ops/pack.toml (falling back to oak/pack.example.toml),
# and AGENT_ROLES filters. site/docs/architecture.html still listed per-organ
# interval triggers and site/docs/quickstart.html still said the planner
# reads VISION.md weekly. #1214 and #1279 flagged this.
#
# Read-only checks against the checkout:
#   1. architecture.html contains oak/tick.sh
#   2. architecture.html states the tick cadence: one tick per POLL_INTERVAL,
#      legal actions from ops/pack.toml / oak/pack.example.toml, AGENT_ROLES
#      filters
#   3. architecture.html no longer claims per-organ intervals (no gardener
#      6h, no planner weekly/12-hour, no "Polling loop: every N" triggers)
#   4. quickstart.html does not claim the planner reads VISION.md weekly;
#      it says the planner runs when the tick picks planner-run
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

ARCH="$REPO_ROOT/site/docs/architecture.html"
QUICK="$REPO_ROOT/site/docs/quickstart.html"
ac_assert_file "$ARCH" "site/docs/architecture.html must exist in the checkout"
ac_assert_file "$QUICK" "site/docs/quickstart.html must exist in the checkout"

# 1. The architecture doc names the tick.
ac_log "checking architecture.html contains oak/tick.sh"
grep -q "oak/tick.sh" "$ARCH" \
  || ac_fail "architecture.html must contain oak/tick.sh"

# 2. The architecture doc states the tick cadence.
ac_log "checking architecture.html states the tick cadence"
grep -q "POLL_INTERVAL" "$ARCH" \
  || ac_fail "architecture.html must say one tick runs per POLL_INTERVAL"
grep -q "ops/pack.toml" "$ARCH" \
  || ac_fail "architecture.html must say legal actions come from ops/pack.toml"
grep -q "oak/pack.example.toml" "$ARCH" \
  || ac_fail "architecture.html must say legal actions fall back to oak/pack.example.toml"
grep -q "AGENT_ROLES" "$ARCH" \
  || ac_fail "architecture.html must say AGENT_ROLES filters the legal actions"

# 3. No per-organ interval trigger claims remain.
ac_log "checking no per-organ interval cadence remains in architecture.html"
for needle in "every 6h" "every 6 h" "6-hour" "weekly" "every 12 hours" "12-hour" "runs daily" "Polling loop: every"; do
  ! grep -qi -e "$needle" "$ARCH" \
    || ac_fail "architecture.html must not claim '$needle' (the oak tick is the cadence, #1351)"
done

# 4. Quickstart no longer says the planner reads VISION.md weekly.
ac_log "checking quickstart.html planner cadence"
! grep -qi "weekly" "$QUICK" \
  || ac_fail "quickstart.html must not claim the planner reads VISION.md weekly"
grep -q "planner-run" "$QUICK" \
  || ac_fail "quickstart.html must say the planner runs when the tick picks planner-run"

echo PASS
