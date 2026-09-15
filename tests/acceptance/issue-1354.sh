#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1354.sh — oak/tick.sh flocks ops/oak for the whole tick
#
# Issue #1354: two Nomad jobs (agents-dev-qwen, agents-review-qwen) tick the
# same $OPS_REPO_ROOT/oak/ and must not interleave last.json / weights.json /
# transitions.jsonl. The one-writer rule is a single exclusive flock on
# $OPS_REPO_ROOT/oak/tick.lock held for the whole critical section
# (sense → pick → td → transition append → last.json write); the organ start
# happens after the lock is released. A busy lock is waited on up to 30s,
# then the tick runs anyway (never skipped).
#
# Verifies, against the repo checkout's oak/tick.sh, running OAK_DRY_RUN=1
# against a private temp ops dir (no organ is ever started, no live state is
# touched):
#   1. oak/tick.sh contains the flock on tick.lock
#   2. two overlapping dry-run ticks on one fixture ops dir: both exit 0
#   3. after the pair plus one more tick, transitions.jsonl has 2 lines
#      (one boot tick + two learned transitions) — every line valid JSON
#      (no torn JSON)
#   4. weights.json and last.json remain valid JSON after all ticks
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
ac_require_cmd flock

TICK="$REPO_ROOT/oak/tick.sh"
ac_assert_file "$TICK" "oak/tick.sh must exist in the checkout"

ac_log "oak/tick.sh contains the flock on tick.lock"
grep -q 'flock' "$TICK" \
  || ac_fail "oak/tick.sh does not use flock"
grep -q 'tick\.lock' "$TICK" \
  || ac_fail "oak/tick.sh does not reference tick.lock"

# env.sh (sourced by tick.sh) hard-requires USER and HOME — provide safe
# defaults when run outside the factory.
export USER="${USER:-acceptance}"
export HOME="${HOME:-/tmp}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# ── Fixture: idle-only learning (no organ is ever picked) ──────────────────
# The standard idle-only fixture from tests/lib/oak-fixture.sh: epsilon=0,
# empty weights → early picks are idle, so OAK_DRY_RUN has little to start.
OPS="$TMP/ops"
REPO="$TMP/repo"
mkdir -p "$REPO"
LOCK="$OPS/oak/tick.lock"
ac_oak_pack "$OPS/pack.toml" '[actions.fixture-organ]
script = "oak/fixture-organ-1354.sh"'
ac_oak_project_toml "$TMP/project.toml" "tick-1354" "$REPO" "$OPS"

TICK_ERR="$TMP/tick-err.log"

# run_tick <out-file> — one OAK_DRY_RUN tick; out-file = stdout (action).
run_tick() {
  env -u AGENT_ROLES -u DISINTO_CONTAINER \
    OAK_DRY_RUN=1 bash "$TICK" "$TMP/project.toml" >"$1" 2>"$TICK_ERR"
}

# ── Two overlapping ticks ───────────────────────────────────────────────────
# A background holder keeps tick.lock busy for 2s while both ticks start, so
# the two ticks really contend: each blocks on the lock (up to 30s), the
# holder releases, and the ticks serialize. Both must exit 0.
ac_log "two overlapping dry-run ticks on one fixture ops dir"
mkdir -p "$OPS/oak"
flock "$LOCK" -c 'sleep 2' &
HOLDER=$!
sleep 1

run_tick "$TMP/out1" &
PID1=$!
run_tick "$TMP/out2" &
PID2=$!

RC1=0
wait "$PID1" || RC1=$?
RC2=0
wait "$PID2" || RC2=$?
wait "$HOLDER" || true

[ "$RC1" -eq 0 ] || ac_oak_tick_fail "overlapping tick 1 exited $RC1" "$TICK_ERR"
[ "$RC2" -eq 0 ] || ac_oak_tick_fail "overlapping tick 2 exited $RC2" "$TICK_ERR"
ac_log "both overlapping ticks exited 0"

# ── One more (uncontended) tick: 3 ticks total = 1 boot + 2 learned ────────
ac_log "third tick (uncontended)"
if ! run_tick "$TMP/out3"; then
  ac_oak_tick_fail "third tick failed" "$TICK_ERR"
fi

# ── State assertions ────────────────────────────────────────────────────────
TRANS="$OPS/oak/transitions.jsonl"
ac_assert_file "$TRANS" "transitions.jsonl must exist after three ticks"
LINES="$(wc -l <"$TRANS")"
[ "$LINES" -eq 2 ] \
  || ac_fail "expected 2 transition lines (1 boot + 2 learned) after three ticks, got $LINES"

# No torn JSON: every line parses and carries the transition fields.
i=0
while IFS= read -r line; do
  i=$((i + 1))
  if ! jq -e '.t and .a and .r and .x and .x2' >/dev/null 2>&1 <<<"$line"; then
    ac_fail "transitions.jsonl line $i is not a valid transition: $line"
  fi
done <"$TRANS"
ac_log "all $LINES transition lines are valid JSON"

WEIGHTS="$OPS/oak/weights.json"
ac_assert_file "$WEIGHTS" "weights.json must exist"
if ! jq -e '.q0 == 1.0' >/dev/null "$WEIGHTS"; then
  ac_fail "weights.json is not valid JSON after both overlapping ticks"
fi

LAST="$OPS/oak/last.json"
ac_assert_file "$LAST" "last.json must exist"
if ! jq -e '.x_key and .a and .x' >/dev/null "$LAST"; then
  ac_fail "last.json is not valid JSON after both overlapping ticks"
fi
[ ! -f "$OPS/oak/last.json.tmp" ] \
  || ac_fail "atomic write left a stray last.json.tmp"

# stdout contract: every tick printed exactly one line (the chosen action).
for out in "$TMP/out1" "$TMP/out2" "$TMP/out3"; do
  [ "$(wc -l <"$out")" -eq 1 ] \
    || ac_fail "tick stdout must be exactly one line (the chosen action), got: $(cat "$out")"
done
ac_assert_eq "$(cat "$TMP/out1")" "idle" "tick 1 must pick idle (all Q at q0, tie → first legal)"
ac_assert_eq "$(cat "$TMP/out2")" "idle" "tick 2 must pick idle (weights still empty: tick 1 was a boot, no td)"
ac_assert_eq "$(cat "$TMP/out3")" "fixture-organ" \
  "tick 3 must pick fixture-organ: the SARSA step dropped idle's Q below q0 (r=0), so q0 beats it"

echo PASS
