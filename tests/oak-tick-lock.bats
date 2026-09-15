#!/usr/bin/env bats
# =============================================================================
# tests/oak-tick-lock.bats — the whole-tick flock in oak/tick.sh (#1354)
#
# Two Nomad jobs (agents-dev-qwen, agents-review-qwen) may tick the same
# $OPS_REPO_ROOT/oak/ at the same moment. The one-writer rule: an exclusive
# flock on $OPS_REPO_ROOT/oak/tick.lock held for the whole critical section
# (sense → pick → td → transition append → last.json write). td.sh/pick.sh
# stay lock-free — tick holds the lock while it calls them. A busy lock is
# waited on up to 30s, then the tick runs anyway (never skipped).
#
# All ticks run OAK_DRY_RUN=1 against a private fixture ops dir: no organ is
# ever started, no live state is touched.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TICK="$ROOT/oak/tick.sh"
  PROJ="$BATS_TEST_TMPDIR/project.toml"
  OPS="$BATS_TEST_TMPDIR/ops"
  REPO="$BATS_TEST_TMPDIR/repo"
  LOCK="$OPS/oak/tick.lock"
  cd "$BATS_TEST_TMPDIR"
  export USER="${USER:-agent}"
  export HOME="${HOME:-/tmp}"
  unset OPS_REPO_ROOT FORGE_API FORGE_TOKEN AGENT_ROLES DISINTO_CONTAINER
  mkdir -p "$OPS" "$REPO"
  touch "$OPS/here"
  # Idle-only fixture (same shape as tests/acceptance/issue-1332.sh):
  # epsilon=0, empty weights → every pick is idle, no organ can start.
  cat >"$OPS/pack.toml" <<'EOF'
[learn]
alpha = 0.1
gamma = 0.99
epsilon = 0
q0 = 1.0

[critic]
builtin = "present"
feature = "done"

[features.here]
rule = "present"
path = "here"

[features.done]
rule = "present"
path = "done"

[actions.idle]
script = ""

[actions.fixture-organ]
script = "oak/fixture-organ-1354.sh"
EOF
  cat >"$PROJ" <<EOF
name = "tick-lock"
repo_root = "$REPO"
ops_repo_root = "$OPS"
primary_branch = "main"
EOF
}

# run_tick — one OAK_DRY_RUN tick; stdout = chosen action (one line).
run_tick() {
  env -u AGENT_ROLES -u DISINTO_CONTAINER \
    OAK_DRY_RUN=1 bash "$TICK" "$PROJ" 2>/dev/null
}

# --- the lock is there -------------------------------------------------------

@test "tick.sh flocks tick.lock for the whole tick" {
  run grep -q 'flock' "$TICK"
  [ "$status" -eq 0 ]
  run grep -q 'tick\.lock' "$TICK"
  [ "$status" -eq 0 ]
}

# --- overlapping ticks: no torn state ----------------------------------------

@test "two overlapping dry-run ticks on one ops dir: both exit 0, no torn JSON" {
  local rc1=0 rc2=0
  run_tick >"$BATS_TEST_TMPDIR/out1" 2>&1 &
  local p1=$!
  run_tick >"$BATS_TEST_TMPDIR/out2" 2>&1 &
  local p2=$!
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  # Under the lock the two ticks serialize: the first is a boot (no
  # transition line), the second learns from the first's last.json —
  # exactly one line, always valid JSON. Without the lock both could
  # boot (0 lines) or race the last.json overwrite.
  [ -f "$OPS/oak/transitions.jsonl" ]
  local lines line
  lines=$(wc -l <"$OPS/oak/transitions.jsonl")
  [ "$lines" -eq 1 ]
  while IFS= read -r line; do
    run jq -e '.a and .r and .x2' <<<"$line"
    [ "$status" -eq 0 ]
  done <"$OPS/oak/transitions.jsonl"

  # last.json: valid JSON with the fields a reader needs.
  run jq -e '.x_key and .a and .x' "$OPS/oak/last.json"
  [ "$status" -eq 0 ]
  # weights.json: still valid JSON (no torn write).
  run jq -e '.q0 == 1.0' "$OPS/oak/weights.json"
  [ "$status" -eq 0 ]
  # the atomic write left no stray tmp
  [ ! -f "$OPS/oak/last.json.tmp" ]
  # both ticks printed exactly one stdout line (the chosen action)
  [ "$(wc -l <"$BATS_TEST_TMPDIR/out1")" -eq 1 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/out2")" -eq 1 ]
}

# --- a busy lock is waited on, never skipped ---------------------------------

@test "tick waits on a held lock and still ticks (never skips)" {
  # Hold the lock for 2s in the background; the tick starts ~1s in and
  # must block on the lock until the holder releases — then still tick
  # (exit 0, last.json written). A skip would leave no last.json.
  mkdir -p "$OPS/oak"
  flock "$LOCK" -c 'sleep 2' &
  local holder=$!
  sleep 1
  local rc=0
  run_tick || rc=$?
  [ "$rc" -eq 0 ]
  wait "$holder" || true
  [ -f "$OPS/oak/last.json" ]
  run jq -e '.x_key and .a and .x' "$OPS/oak/last.json"
  [ "$status" -eq 0 ]
}

# --- the lock is released by the tick ----------------------------------------

@test "a finished tick releases tick.lock (flock -n succeeds right after)" {
  run run_tick
  [ "$status" -eq 0 ]
  [ "$output" = "idle" ]
  # The tick's fd 9 closed after the last.json write: a new process can
  # take the lock immediately.
  run flock -n "$LOCK" -c 'true'
  [ "$status" -eq 0 ]
}
