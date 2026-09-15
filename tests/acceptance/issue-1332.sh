#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1332.sh — oak/tick.sh one-tick driver
#
# Issue #1332 (oak tick-learner sprint): one tick = sense → critic (r) →
# pick a2 → SARSA td → transition log → start at most one organ.
#
# Verifies, against the repo checkout's oak/tick.sh, running against private
# temp dirs with OAK_DRY_RUN=1 (no organ is ever started, no live state is
# touched):
#   1. OAK_DRY_RUN=1: two dry ticks in a fixture ops dir; the first tick is
#      a boot (writes last.json, no transition line); the second tick
#      appends exactly one transition line with r=0
#   2. weights.json exists after the second dry tick; the idle Q at the
#      fixture's state key moved off q0 (SARSA update applied)
#   3. DRY_RUN never starts the picked organ (pgrep: the fixture organ
#      never appears in the process table)
#   4. with vault.mode="manual", dispatch is not chosen even when its Q is
#      the highest in the table (the seeded weights make this a real pick)
#   5. with NO [vault] table at all, dispatch is still not chosen: a
#      missing [vault] means max_in_flight 0, so dispatch is always
#      dropped (never legal-but-never-startable)
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/oak-fixture.sh"

ac_require_cmd bash
ac_require_cmd jq
ac_require_cmd python3
ac_require_cmd pgrep

TICK="$REPO_ROOT/oak/tick.sh"
ac_assert_file "$TICK" "oak/tick.sh must exist in the checkout"

# env.sh (sourced by tick.sh) hard-requires USER and HOME — provide safe
# defaults when run outside the factory.
export USER="${USER:-acceptance}"
export HOME="${HOME:-/tmp}"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
cd "$TMPD"

TICK_ERR="$TMPD/tick-err.log"

# run_tick <project.toml> — one OAK_DRY_RUN tick; stdout = chosen action.
run_tick() {
  env -u AGENT_ROLES -u DISINTO_CONTAINER \
    OAK_DRY_RUN=1 bash "$TICK" "$1" 2>"$TICK_ERR"
}

# ── Fixture A: idle-only learning (no organ is ever picked) ───────────────
# pack: two `present` features (here=1, done=0 → key "0|1"), critic on
# "done" (absent → r=0 always). Actions: idle + gardener-step. Only two
# ticks are run, and both pick idle: at tick 2's pick the weights table is
# still empty (tick 1 is a boot — no td), so every action reads as q0 and
# the ε=0 tie breaks to the first legal entry, idle.
OPS_A="$TMPD/ops-a"
REPO_A="$TMPD/repo-a"
mkdir -p "$REPO_A"
ac_oak_pack "$OPS_A/pack.toml" '[actions.gardener-step]
script = "gardener/gardener-step.sh"' '[vault]
mode = "manual"
max_in_flight = 1'

ac_oak_project_toml "$TMPD/project-a.toml" "tick-a" "$REPO_A" "$OPS_A"

ac_log "fixture A, tick 1 (boot): prints idle, writes last.json, no transition"
if ! OUT_A1="$(run_tick "$TMPD/project-a.toml")"; then
  ac_oak_tick_fail "fixture A tick 1 failed" "$TICK_ERR"
fi
ac_assert_eq "$OUT_A1" "idle" "fixture A tick 1 must pick idle (all Q at q0, tie → first legal)"
[ -f "$OPS_A/oak/last.json" ] \
  || ac_fail "boot tick must write last.json"
[ ! -f "$OPS_A/oak/transitions.jsonl" ] \
  || ac_fail "boot tick must not append a transition line (no previous tick)"
ac_assert_jq '.a == "idle" and .x_key == "0|1"' "$(cat "$OPS_A/oak/last.json")" \
  "last.json after tick 1 must record a=idle and the sensed key 0|1"
ac_assert_jq '.x == {"done":0,"here":1}' "$(cat "$OPS_A/oak/last.json")" \
  "last.json must store the raw state x"

ac_log "fixture A, tick 2: prints idle, appends one r=0 transition, idle Q moves off q0"
if ! OUT_A2="$(run_tick "$TMPD/project-a.toml")"; then
  ac_oak_tick_fail "fixture A tick 2 failed" "$TICK_ERR"
fi
ac_assert_eq "$OUT_A2" "idle" "fixture A tick 2 must print the chosen action (idle)"

TRANS_A="$OPS_A/oak/transitions.jsonl"
ac_assert_file "$TRANS_A" "second tick must append to transitions.jsonl"
[ "$(wc -l <"$TRANS_A")" -eq 1 ] \
  || ac_fail "exactly one transition line after two ticks, got $(wc -l <"$TRANS_A")"
ac_assert_jq '.r == 0' "$(head -n1 "$TRANS_A")" \
  "transition r must be 0 (critic: done absent)"
ac_assert_jq '.a == "idle"' "$(head -n1 "$TRANS_A")" \
  "transition a must be the previous tick's action (idle)"
ac_assert_jq '.x == {"done":0,"here":1} and .x2 == {"done":0,"here":1}' \
  "$(head -n1 "$TRANS_A")" \
  "transition must store previous x and current x2 (both 0|1 states)"

WEIGHTS_A="$OPS_A/oak/weights.json"
ac_assert_file "$WEIGHTS_A" "weights.json must exist after the second dry tick"
ac_assert_jq '.gvf.purpose.Q["0|1"].idle != 1.0' "$(cat "$WEIGHTS_A")" \
  "idle Q at the fixture key must have moved off q0 (SARSA applied)"
ac_assert_jq '(.gvf.purpose.Q["0|1"].idle) < 1.0' "$(cat "$WEIGHTS_A")" \
  "idle Q must drop below q0 (r=0, gamma*q2 < q): expected 0.999"
ac_assert_jq '.q0 == 1.0' "$(cat "$WEIGHTS_A")" \
  "weights table must keep q0"

# ── Fixture B: organ pick + dispatch under a manual vault ─────────────────
# Seeded Q: fixture-organ=10, dispatch=100, idle=q0=1. Greedy must pick the
# organ (10) — dispatch (100) is dropped because vault.mode="manual". If the
# manual-mode drop were broken, tick would pick dispatch. A uniquely named
# organ script makes the "never started" pgrep assertion precise (no live
# box false positives).
OPS_B="$TMPD/ops-b"
REPO_B="$TMPD/repo-b"
mkdir -p "$OPS_B/oak" "$REPO_B"
ac_oak_pack "$OPS_B/pack.toml" '[actions.fixture-organ]
script = "oak/fixture-organ-1332.sh"

[actions.dispatch]
script = "docker/edge/dispatcher.sh"' '[vault]
mode = "manual"
max_in_flight = 1'

ac_oak_project_toml "$TMPD/project-b.toml" "tick-b" "$REPO_B" "$OPS_B"

cat >"$OPS_B/oak/weights.json" <<'EOF'
{"q0":1.0,"gvf":{"purpose":{"Q":{"0|1":{"fixture-organ":10.0,"dispatch":100.0}}},"inbound":{"V":{}}}}
EOF

ac_log "fixture B, tick 1: dispatch (Q=100) is not chosen under vault.mode=manual"
if ! OUT_B1="$(run_tick "$TMPD/project-b.toml")"; then
  ac_oak_tick_fail "fixture B tick 1 failed" "$TICK_ERR"
fi
ac_assert_eq "$OUT_B1" "fixture-organ" \
  "pick must be fixture-organ (Q=10); dispatch (Q=100) is dropped under vault.mode=manual"
if pgrep -f "fixture-organ-1332.sh" >/dev/null 2>&1; then
  ac_fail "OAK_DRY_RUN must never start the organ (fixture-organ-1332.sh is running)"
fi
[ ! -f "$OPS_B/oak/transitions.jsonl" ] \
  || ac_fail "fixture B tick 1 is a boot: no transition line expected"
ac_assert_jq '.a == "fixture-organ" and .x_key == "0|1"' \
  "$(cat "$OPS_B/oak/last.json")" \
  "last.json after fixture B tick 1 must record the picked organ"

ac_log "fixture B, tick 2: organ picked again, transition appended, Q updated, still not started"
if ! OUT_B2="$(run_tick "$TMPD/project-b.toml")"; then
  ac_oak_tick_fail "fixture B tick 2 failed" "$TICK_ERR"
fi
ac_assert_eq "$OUT_B2" "fixture-organ" "fixture B tick 2 must pick the organ again"
TRANS_B="$OPS_B/oak/transitions.jsonl"
ac_assert_file "$TRANS_B" "fixture B tick 2 must append to transitions.jsonl"
[ "$(wc -l <"$TRANS_B")" -eq 1 ] \
  || ac_fail "fixture B: exactly one transition line after two ticks, got $(wc -l <"$TRANS_B")"
ac_assert_jq '.a == "fixture-organ" and .r == 0' "$(head -n1 "$TRANS_B")" \
  "fixture B transition must carry the organ action and r=0"
if pgrep -f "fixture-organ-1332.sh" >/dev/null 2>&1; then
  ac_fail "OAK_DRY_RUN must never start the organ (fixture-organ-1332.sh is running)"
fi
ac_assert_jq '(.gvf.purpose.Q["0|1"]["fixture-organ"]) < 10.0' \
  "$(cat "$OPS_B/oak/weights.json")" \
  "fixture-organ Q must drop below its 10.0 seed (SARSA, r=0)"
ac_assert_jq '(.gvf.purpose.Q["0|1"]["dispatch"]) == 100.0' \
  "$(cat "$OPS_B/oak/weights.json")" \
  "dispatch Q must be untouched (it was never the taken action)"

# ── Fixture C: dispatch with NO [vault] table at all ───────────────────────
# Same seeded Q as fixture B (dispatch=100 beats idle's q0=1), but the pack
# has no [vault] section: that means max_in_flight 0, so dispatch must be
# dropped and idle picked. Pre-fix, dispatch (100) won this pick.
OPS_C="$TMPD/ops-c"
REPO_C="$TMPD/repo-c"
mkdir -p "$OPS_C/oak" "$REPO_C"
ac_oak_pack "$OPS_C/pack.toml" '[actions.dispatch]
script = "docker/edge/dispatcher.sh"'

ac_oak_project_toml "$TMPD/project-c.toml" "tick-c" "$REPO_C" "$OPS_C"

cat >"$OPS_C/oak/weights.json" <<'EOF'
{"q0":1.0,"gvf":{"purpose":{"Q":{"0|1":{"dispatch":100.0}}},"inbound":{"V":{}}}}
EOF

ac_log "fixture C, tick 1: dispatch (Q=100) is not chosen with no [vault] table"
if ! OUT_C1="$(run_tick "$TMPD/project-c.toml")"; then
  ac_oak_tick_fail "fixture C tick 1 failed" "$TICK_ERR"
fi
ac_assert_eq "$OUT_C1" "idle" \
  "pick must be idle: a missing [vault] means max_in_flight 0, so dispatch (Q=100) is dropped"
ac_assert_jq '.a == "idle" and .x_key == "0|1"' \
  "$(cat "$OPS_C/oak/last.json")" \
  "last.json after fixture C tick 1 must record idle, not dispatch"
[ ! -f "$OPS_C/oak/transitions.jsonl" ] \
  || ac_fail "fixture C tick 1 is a boot: no transition line expected"

ac_log "stdout contract: every tick printed exactly one line"
for out in "$OUT_A1" "$OUT_A2" "$OUT_B1" "$OUT_B2" "$OUT_C1"; do
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
    || ac_fail "tick stdout must be exactly one line (the chosen action), got: $out"
done

echo PASS
