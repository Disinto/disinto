#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1698.sh
#
# Issue #1698: judge Woodpecker agent health from the Woodpecker API, not
# docker inspect. The supervisor image has no docker CLI, and under Nomad
# the agent container is not named disinto-woodpecker-agent.
#
#   1. wp_agent_last_contact_age pages /agents (50 per page) and prints
#      now minus the largest last_contact. Page 1 of 50 (newest now-900)
#      and page 2 of 11 (newest now-5) yields an age from 5 to 7.
#   2. A failing woodpecker_api stub: print nothing, return 1.
#   3. wp_agent_health_verdict: age 5 → healthy; age 900 → UNHEALTHY;
#      no age and 0 fast failures → unknown.
#   4. wp-agent-unhealthy is action: incident with no action_script,
#      wp-agent-restart.sh is gone, and the supervisor job sets
#      WOODPECKER_SERVER and renders WOODPECKER_TOKEN.
#
# Hermetic: no network. woodpecker_api is a shell function.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd date
ac_require_cmd grep

LIB="$REPO_ROOT/lib/wp-agent-health.sh"
PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
RECIPES="$REPO_ROOT/supervisor/recipes.yaml"
JOB="$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"
ac_assert_file "$LIB" "lib/wp-agent-health.sh must exist"
ac_assert_file "$PREFLIGHT" "supervisor/preflight.sh must exist"
ac_assert_file "$RECIPES" "supervisor/recipes.yaml must exist"
ac_assert_file "$JOB" "agents-supervisor-opus.hcl must exist"

# shellcheck source=../../lib/wp-agent-health.sh
source "$LIB"

# ── 1. newest contact is on page 2, not the stale page of 50 ────────────────
ac_log "AC 1: two pages, newest contact now-5, age is 5 to 7"

# Called from wp_agent_last_contact_age, not from this file.
# shellcheck disable=SC2317
woodpecker_api() {
  local now
  now="$(date +%s)"
  case "$1" in
    "/agents?page=1&perPage=50")
      jq -n --argjson now "$now" '[range(50) | {id: ., last_contact: ($now - 900)}]'
      ;;
    "/agents?page=2&perPage=50")
      jq -n --argjson now "$now" '
        [range(11) | {id: (50 + .), last_contact: ($now - 800)}]
        | .[0].last_contact = ($now - 5)
      '
      ;;
    *)
      return 1
      ;;
  esac
}

rc=0
age_out="$(wp_agent_last_contact_age)" || rc=$?
ac_assert_eq "$rc" "0" "paginated agent list must return 0, got $rc (out: $age_out)"
[[ "$age_out" =~ ^[0-9]+$ ]] || ac_fail "expected an integer age, got: $age_out"
if [ "$age_out" -lt 5 ] || [ "$age_out" -gt 7 ]; then
  ac_fail "expected age from 5 to 7, got $age_out"
fi

# ── 2. a failed request prints nothing and returns 1 ────────────────────────
ac_log "AC 2: failing woodpecker_api prints nothing and returns 1"

# shellcheck disable=SC2317
woodpecker_api() {
  printf 'should-not-leak\n'
  return 1
}
rc=0
age_out="$(wp_agent_last_contact_age)" || rc=$?
ac_assert_eq "$rc" "1" "a failed request must return 1, got $rc"
ac_assert_eq "$age_out" "" "a failed request must print nothing, got: $age_out"

# ── 3. verdict: healthy / UNHEALTHY / unknown ───────────────────────────────
ac_log "AC 3: verdict age 5 healthy, age 900 UNHEALTHY, no age unknown"

VERDICT_SRC="$(ac_extract_fn wp_agent_health_verdict "$PREFLIGHT")"
[ -n "$VERDICT_SRC" ] || ac_fail "could not extract wp_agent_health_verdict() from preflight.sh"
# shellcheck disable=SC1090
eval "$VERDICT_SRC"

unset WP_AGENT_CONTACT_MAX_S
ac_assert_eq "$(wp_agent_health_verdict 5 0)" "healthy" \
  "age 5 must be healthy"
ac_assert_eq "$(wp_agent_health_verdict 900 0)" "UNHEALTHY" \
  "age 900 must be UNHEALTHY"
ac_assert_eq "$(wp_agent_health_verdict "" 0)" "unknown" \
  "no age and 0 fast failures must be unknown"

# The assignment is a source string, not an expansion.
# shellcheck disable=SC2016
grep -q 'age="$(wp_agent_last_contact_age)" || age=""' "$PREFLIGHT" \
  || ac_fail "preflight must call wp_agent_last_contact_age with the empty-age fallback"
grep -q 'WP Agent Health:' "$PREFLIGHT" \
  || ac_fail "preflight must print WP Agent Health"

# ── 4. incident, no restart script, supervisor job has the API env ──────────
ac_log "AC 4: recipe is an incident, restart script is gone, job has the API env"

if [ -e "$REPO_ROOT/supervisor/actions/wp-agent-restart.sh" ]; then
  ac_fail "supervisor/actions/wp-agent-restart.sh must be deleted"
fi

recipe="$(awk '
  $0 ~ /^  - name: wp-agent-unhealthy$/ { p = 1; print; next }
  p && /^  - name:/ { exit }
  p { print }
' "$RECIPES")"
[ -n "$recipe" ] || ac_fail "wp-agent-unhealthy recipe is missing"
printf '%s\n' "$recipe" | grep -q 'action: incident' \
  || ac_fail "wp-agent-unhealthy must be action: incident, got: $recipe"
if printf '%s\n' "$recipe" | grep -q 'action_script:'; then
  ac_fail "wp-agent-unhealthy must not set action_script, got: $recipe"
fi

grep -q 'WOODPECKER_SERVER  = "http://10.10.10.132:8000/ci"' "$JOB" \
  || ac_fail "supervisor job must set WOODPECKER_SERVER"
grep -q 'WOODPECKER_REPO_ID = "1"' "$JOB" \
  || ac_fail "supervisor job must set WOODPECKER_REPO_ID"
grep -q 'kv/data/disinto/shared/ci' "$JOB" \
  || ac_fail "supervisor job must read kv/data/disinto/shared/ci"
grep -q 'WOODPECKER_TOKEN={{ .Data.data.woodpecker_token }}' "$JOB" \
  || ac_fail "supervisor job must render WOODPECKER_TOKEN"

ac_pass
