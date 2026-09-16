#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1351.sh — site docs say cadence scheduler + dry-run
# shadow tick
#
# Issue #1351 (docs) originally made the site docs match the tick-only
# policy (#1333). #1388 restored the per-organ cadence scheduler (dev/review
# every 5 min, supervisor 20 min, architect 15 min, gardener 6h, planner
# 12h, predictor daily) and demoted the oak tick to a dry-run shadow
# (OAK_DRY_RUN=1 — senses, picks, logs, never execs). This test now pins the
# post-#1388 wording.
#
# Read-only checks against the checkout:
#   1. architecture.html contains oak/tick.sh
#   2. architecture.html states the per-organ cadence (dev/review 5 min,
#      supervisor 20 min, architect 15 min, gardener 6h, planner 12h,
#      predictor daily)
#   3. architecture.html names the tick as a dry-run shadow with
#      OAK_DRY_RUN=1, still mentions POLL_INTERVAL, the pack sources
#      (ops/pack.toml / oak/pack.example.toml), and the AGENT_ROLES filter
#   4. quickstart.html says the planner reads VISION.md every 12 hours (not
#      weekly, not "when a tick picks planner-run")
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

# 2. The architecture doc states the per-organ cadence.
ac_log "checking architecture.html states the per-organ cadence"
for needle in "every 5 min" "every 20 min" "every 15 min" "every 6h" "every 12h" "daily"; do
  grep -qi "$needle" "$ARCH" \
    || ac_fail "architecture.html must describe the per-organ intervals (expected '$needle')"
done

# 3. The tick is named as a dry-run shadow; the pack sources and the
#    AGENT_ROLES filter are still mentioned.
ac_log "checking architecture.html names the dry-run shadow tick"
grep -q "OAK_DRY_RUN=1" "$ARCH" \
  || ac_fail "architecture.html must say the tick runs as a dry-run shadow (OAK_DRY_RUN=1)"
grep -qi "shadow" "$ARCH" \
  || ac_fail "architecture.html must call the tick a dry-run shadow"
grep -q "POLL_INTERVAL" "$ARCH" \
  || ac_fail "architecture.html must mention the tick runs per POLL_INTERVAL"
grep -q "ops/pack.toml" "$ARCH" \
  || ac_fail "architecture.html must say legal actions come from ops/pack.toml"
grep -q "oak/pack.example.toml" "$ARCH" \
  || ac_fail "architecture.html must say legal actions fall back to oak/pack.example.toml"
grep -q "AGENT_ROLES" "$ARCH" \
  || ac_fail "architecture.html must say AGENT_ROLES filters which organs a house runs"

# 4. Quickstart says the planner reads VISION.md every 12 hours.
ac_log "checking quickstart.html planner cadence"
! grep -qi "weekly" "$QUICK" \
  || ac_fail "quickstart.html must not claim the planner reads VISION.md weekly"
grep -qi "every 12 hours" "$QUICK" \
  || ac_fail "quickstart.html must say the planner reads VISION.md every 12 hours"
! grep -q "tick picks" "$QUICK" \
  || ac_fail "quickstart.html must not claim the planner runs when a tick picks planner-run (the cadence scheduler was restored by #1388)"

echo PASS
