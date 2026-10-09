#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1988.sh
#
# Issue #1988: the public-endpoint pass must honour the shared per-tick
# restart cap (HEALER_MAX_RESTARTS) for unhealthy backends too. A tick that
# has already restarted 3 allocations must not restart a 4th, and the capped
# URL is still noted for escalation.
#
# Hermetic: shared curl/nomad stubs. Three unregistered service jobs consume
# the budget in the service pass; the forge URL is already on a 2-tick streak
# so this tick would otherwise restart its backend.
#
#   AC1  budget spent, forgejo UNHEALTHY -> no 4th restart, episode noted,
#        not unfixable. Next tick (budget free) still restarts forgejo.
#   AC2  budget spent, forgejo HEALTHY -> no edge restart, episode noted,
#        not unfixable (#1987 note preserved).
#
# Run via: tools/run-acceptance.sh 1988
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/healer-stubs.sh
source "$REPO_ROOT/tests/lib/healer-stubs.sh"

ac_require_cmd bash jq grep mktemp date

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

ac_healer_init "${TMPDIR:-/tmp}/healer-1988.XXXXXX"
ac_healer_public_fixtures

FORGE_URL="https://self.disinto.ai/forge/"
FORGE_COND="public-endpoint-down:${FORGE_URL}"
export HEALER_TEST_PUBLIC_URLS="$FORGE_URL"

# Three running service jobs whose services are not registered. The service
# pass restarts each of them and exhausts the shared budget before the
# endpoint pass runs. forgejo / woodpecker / edge stay registered.
add_budget_jobs() {
  local id
  for id in extra-a extra-b extra-c; do
    jq -n --arg id "$id" \
      '{ID:$id,TaskGroups:[{Name:$id,Services:[{Name:$id}],Tasks:[{Name:$id,Services:[]}]}]}' \
      > "$DATA/job-$id.json"
    jq -n --arg id "$id" --arg alloc "alloc-$id" \
      '[{ID:$alloc,JobID:$id,ClientStatus:"running"}]' \
      > "$DATA/allocs-$id.json"
  done
  jq -n '[
    {ID:"forgejo",Status:"running",Type:"service"},
    {ID:"woodpecker-server",Status:"running",Type:"service"},
    {ID:"edge",Status:"running",Type:"service"},
    {ID:"extra-a",Status:"running",Type:"service"},
    {ID:"extra-b",Status:"running",Type:"service"},
    {ID:"extra-c",Status:"running",Type:"service"}
  ]' > "$DATA/jobs.json"
}

# Streak of 2 so the next failing probe is the one that would act.
seed_streak() {
  local state_dir="$1"
  mkdir -p "$state_dir"
  jq -n --arg u "$FORGE_URL" '{failures:{($u):2}}' > "$state_dir/state.json"
}

episode_detail() {
  local state_dir="$1"
  jq -r --arg c "$FORGE_COND" '.episodes[$c].detail // ""' "$state_dir/state.json"
}

add_budget_jobs

# ── AC1: budget spent, unhealthy backend must not be a 4th restart ──────────
ac_log "AC1: 3 service restarts then unhealthy /forge/ -> no 4th restart, still noted"
STATE_DIR="$WORK/st-1"
TAPE_DIR="$WORK/tp-1"
STUB_LOG="$WORK/nm-1.log"
seed_streak "$STATE_DIR"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
set_probe_code forge 502
set_probe_code forgejo 503
clear_probe_code ci
clear_probe_code woodpecker

rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC1 exit 0, got $rc: $out"
ac_assert_eq "$(healer_restart_lines)" "3" \
  "AC1 exactly 3 restarts (budget), not a 4th: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of extra-a)" "1" "AC1 restarted extra-a"
ac_assert_eq "$(healer_restarts_of extra-b)" "1" "AC1 restarted extra-b"
ac_assert_eq "$(healer_restarts_of extra-c)" "1" "AC1 restarted extra-c"
ac_assert_eq "$(healer_restarts_of forgejo)" "0" \
  "AC1 must not restart unhealthy forgejo past the cap: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "0" "AC1 must not restart edge"
printf '%s\n' "$out" | grep -q "restart cap reached — ${FORGE_URL} waits" \
  || ac_fail "AC1 capped URL must be logged as waiting, got: $out"
detail="$(episode_detail "$STATE_DIR")"
case "$detail" in
  *unhealthy*) ;;
  *) ac_fail "AC1 capped URL must be noted for escalation (unhealthy), got: ${detail}" ;;
esac
jq -e --arg u "$FORGE_URL" '(.endpoint_open // {}) | has($u) | not' \
  "$STATE_DIR/state.json" >/dev/null \
  || ac_fail "AC1 must not record an endpoint restart, got: $(cat "$STATE_DIR/state.json")"
jq -e --arg u "$FORGE_URL" '(.unfixable // {}) | has($u) | not' \
  "$STATE_DIR/state.json" >/dev/null \
  || ac_fail "AC1 cap must not mark the URL unfixable, got: $(cat "$STATE_DIR/state.json")"

ac_log "AC1b: next tick, budget free, unhealthy forgejo is still restarted"
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC1b exit 0, got $rc: $out"
ac_assert_eq "$(healer_restarts_of forgejo)" "1" \
  "AC1b restarts forgejo once the budget is free: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "0" "AC1b must not restart edge"
ac_assert_eq "$(healer_restart_lines)" "4" \
  "AC1b one more restart, still within a fresh tick budget: $(cat "$STUB_LOG")"

# ── AC2: same budget exhaustion, healthy backend (edge) also capped ─────────
ac_log "AC2: 3 service restarts then healthy /forge/ -> no edge restart, still noted"
STATE_DIR="$WORK/st-2"
TAPE_DIR="$WORK/tp-2"
STUB_LOG="$WORK/nm-2.log"
seed_streak "$STATE_DIR"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
set_probe_code forge 502
set_probe_code forgejo 200
clear_probe_code ci
clear_probe_code woodpecker

rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC2 exit 0, got $rc: $out"
ac_assert_eq "$(healer_restart_lines)" "3" \
  "AC2 exactly 3 restarts, not an edge 4th: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "0" \
  "AC2 must not restart edge past the cap: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of forgejo)" "0" "AC2 must not restart forgejo"
printf '%s\n' "$out" | grep -q "restart cap reached — ${FORGE_URL} waits" \
  || ac_fail "AC2 capped URL must be logged as waiting, got: $out"
detail="$(episode_detail "$STATE_DIR")"
case "$detail" in
  *healthy*) ;;
  *) ac_fail "AC2 capped URL must be noted for escalation (healthy), got: ${detail}" ;;
esac
jq -e --arg u "$FORGE_URL" '(.unfixable // {}) | has($u) | not' \
  "$STATE_DIR/state.json" >/dev/null \
  || ac_fail "AC2 cap must not mark the URL unfixable, got: $(cat "$STATE_DIR/state.json")"

ac_pass
