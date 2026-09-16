#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1333.sh — entrypoint runs oak/tick.sh (dry-run shadow)
#
# Issue #1333 introduced the oak tick as the sole scheduler. #1388 restored
# the per-organ cadence scheduler on top: the entrypoint again paces each
# organ on its own interval (dev-poll/review-poll every loop, gardener 6h,
# architect 15 min, planner 12h, predictor 24h, supervisor 20 min), while
# oak/tick.sh keeps running alongside each project as a DRY-RUN SHADOW
# (OAK_DRY_RUN=1) — it senses, picks, and logs the organ it WOULD start but
# never execs one. The tick learner retires in #1390.
#
# Read-only checks against the checkout's docker/agents/entrypoint.sh:
#   1. contains oak/tick.sh and runs 'bash oak/tick.sh' — the tick still runs
#      per project per loop
#   2. the tick runs in dry-run shadow mode: OAK_DRY_RUN=1 is set in the
#      tick invocation
#   3. the per-organ cadence scheduler is back: the interval variables
#      (GARDENER_INTERVAL, ARCHITECT_INTERVAL, PLANNER_INTERVAL,
#      SUPERVISOR_INTERVAL), the organ script paths, the pgrep one-instance
#      guards, and the FAST_PIDS background starts for the fast organs
#   4. still sleeps POLL_INTERVAL — the base loop clock
#   5. still exports AGENT_ROLES — house filter for organ starts AND the
#      gosu'd tick
#   6. still exports the per-TOML vars the organs and tick.sh need
#      (OPS_REPO_ROOT is a hard precondition in tick.sh;
#      PROJECT_NAME/PROJECT_REPO_ROOT/PRIMARY_BRANCH satisfy env.sh
#      preconditions)
#   7. bash -n — the script is syntactically valid
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

EP="$REPO_ROOT/docker/agents/entrypoint.sh"
ac_assert_file "$EP" "docker/agents/entrypoint.sh must exist in the checkout"

# 1. The loop still runs oak/tick.sh per project per loop.
ac_log "checking the loop calls oak/tick.sh"
grep -q "oak/tick.sh" "$EP" \
  || ac_fail "entrypoint.sh must call oak/tick.sh"
grep -q 'bash oak/tick.sh' "$EP" \
  || ac_fail "entrypoint.sh must run 'bash oak/tick.sh' per project TOML"

# 2. The tick is a dry-run shadow (#1388): OAK_DRY_RUN=1 in the invocation,
#    so it senses/picks/logs but never execs an organ.
ac_log "checking the tick runs with OAK_DRY_RUN=1"
grep -q 'OAK_DRY_RUN=1 bash oak/tick.sh' "$EP" \
  || ac_fail "the oak tick must run in dry-run shadow mode (OAK_DRY_RUN=1 bash oak/tick.sh)"

# 3. The per-organ cadence scheduler is restored (#1388): interval variables,
#    organ script paths, pgrep one-instance guards, FAST_PIDS background
#    starts for the fast organs.
ac_log "checking the per-organ cadence scheduler is present"
for var in GARDENER_INTERVAL ARCHITECT_INTERVAL PLANNER_INTERVAL SUPERVISOR_INTERVAL; do
  grep -q "$var" "$EP" \
    || ac_fail "entrypoint.sh must contain $var (per-organ cadence restored by #1388)"
done
for organ in review/review-poll.sh dev/dev-poll.sh gardener/gardener-run.sh architect/architect-run.sh planner/planner-run.sh predictor/predictor-run.sh supervisor/supervisor-run.sh; do
  grep -q "${organ##*/}" "$EP" \
    || ac_fail "entrypoint.sh must pace ${organ##*/} on its own interval"
done
grep -q "pgrep" "$EP" \
  || ac_fail "entrypoint.sh must carry the pgrep one-instance guards for slow organs"
grep -q "FAST_PIDS" "$EP" \
  || ac_fail "entrypoint.sh must background the fast organs via FAST_PIDS"

# 4. Still sleeps POLL_INTERVAL (the base loop clock).
ac_log "checking the loop still sleeps POLL_INTERVAL"
grep -Eq 'sleep[[:space:]]+"\$\{POLL_INTERVAL\}"' "$EP" \
  || ac_fail "entrypoint.sh must still sleep \${POLL_INTERVAL}"

# 5. AGENT_ROLES is still exported — house filter for organ starts and for
#    the gosu'd tick.
ac_log "checking AGENT_ROLES is exported"
grep -Eq '^[[:space:]]*export[[:space:]]+AGENT_ROLES=' "$EP" \
  || ac_fail "entrypoint.sh must export AGENT_ROLES (house filter for organs and tick)"

# 6. The per-TOML exports the organs and tick.sh need are still there.
ac_log "checking per-TOML env exports survive"
for var in PROJECT_NAME PROJECT_REPO_ROOT OPS_REPO_ROOT PRIMARY_BRANCH; do
  grep -q "export $var=" "$EP" \
    || ac_fail "entrypoint.sh must still export $var per project TOML"
done

# 7. The script is syntactically valid.
ac_log "checking bash -n"
bash -n "$EP" 2>/dev/null \
  || ac_fail "docker/agents/entrypoint.sh fails bash -n"

echo PASS
