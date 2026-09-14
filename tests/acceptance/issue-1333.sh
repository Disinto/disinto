#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1333.sh — entrypoint runs oak/tick.sh
#
# Issue #1333 (oak tick-learner sprint): the entrypoint no longer starts
# organs on hard-coded intervals. One tick per project per loop: for each
# project TOML the loop runs oak/tick.sh, which is the policy — it senses,
# picks, and starts at most one organ. The entrypoint never calls organs
# itself and never waits on them.
#
# Read-only checks against the checkout's docker/agents/entrypoint.sh:
#   1. contains oak/tick.sh — the loop calls it
#   2. does not contain review-poll.sh — organs are not started from the
#      entrypoint anymore (no organ script path at all)
#   3. does not contain ARCHITECT_INTERVAL or predictor_interval — the
#      fixed clocks (and with them the other *_INTERVAL variables) are gone
#   4. still sleeps POLL_INTERVAL — one clock, the tick cadence
#   5. still assigns AGENT_ROLES — tick.sh uses it as a house filter
#   6. still exports the per-TOML vars tick.sh needs (OPS_REPO_ROOT is a
#      hard precondition in tick.sh; PROJECT_NAME/PROJECT_REPO_ROOT/
#      PRIMARY_BRANCH satisfy env.sh preconditions)
#   7. bash -n — the rewrite kept the script syntactically valid
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

# 1. The loop calls oak/tick.sh (one tick per project per loop).
ac_log "checking the loop calls oak/tick.sh"
grep -q "oak/tick.sh" "$EP" \
  || ac_fail "entrypoint.sh must call oak/tick.sh"
grep -q 'bash oak/tick.sh' "$EP" \
  || ac_fail "entrypoint.sh must run 'bash oak/tick.sh' per project TOML"

# 2. No organ script is started from the entrypoint (tick.sh is the policy).
ac_log "checking no organ script is referenced"
! grep -q "review-poll.sh" "$EP" \
  || ac_fail "entrypoint.sh must not reference review-poll.sh (tick.sh is the policy)"
for organ in dev/dev-poll.sh gardener/gardener-step.sh architect/architect-run.sh planner/planner-run.sh predictor/predictor-run.sh supervisor/supervisor-run.sh; do
  ! grep -q "${organ##*/}" "$EP" \
    || ac_fail "entrypoint.sh must not start ${organ##*/} (tick.sh is the policy)"
done
# The pgrep/FAST_PIDS guards existed only to start those scripts — gone too.
! grep -q "pgrep" "$EP" \
  || ac_fail "entrypoint.sh must not carry the old pgrep organ guards"
! grep -q "FAST_PIDS" "$EP" \
  || ac_fail "entrypoint.sh must not carry FAST_PIDS (no background organ starts)"

# 3. No fixed clocks: the interval variables and the 24h predictor math are
#    gone — the only remaining clock is POLL_INTERVAL.
ac_log "checking the fixed interval clocks are gone"
for var in ARCHITECT_INTERVAL PLANNER_INTERVAL SUPERVISOR_INTERVAL predictor_interval; do
  ! grep -q "$var" "$EP" \
    || ac_fail "entrypoint.sh must not contain $var (one clock: POLL_INTERVAL)"
done

# 4. Still sleeps POLL_INTERVAL (the single tick cadence).
ac_log "checking the loop still sleeps POLL_INTERVAL"
grep -Eq 'sleep[[:space:]]+"\$\{POLL_INTERVAL\}"' "$EP" \
  || ac_fail "entrypoint.sh must still sleep \${POLL_INTERVAL}"

# 5. AGENT_ROLES is still assigned — tick.sh uses it as a house filter.
ac_log "checking AGENT_ROLES is still assigned"
grep -q '^[[:space:]]*AGENT_ROLES=' "$EP" \
  || ac_fail "entrypoint.sh must still assign AGENT_ROLES (tick.sh house filter)"

# 6. The per-TOML exports tick.sh / the organs need are still there.
ac_log "checking per-TOML env exports survive"
for var in PROJECT_NAME PROJECT_REPO_ROOT OPS_REPO_ROOT PRIMARY_BRANCH; do
  grep -q "export $var=" "$EP" \
    || ac_fail "entrypoint.sh must still export $var per project TOML"
done

# 7. The rewrite kept the script syntactically valid.
ac_log "checking bash -n"
bash -n "$EP" 2>/dev/null \
  || ac_fail "docker/agents/entrypoint.sh fails bash -n"

echo PASS
