#!/usr/bin/env bats
# =============================================================================
# tests/oak-status.bats — unit tests for oak/status.sh (#1352)
#
# One command for the live learner's last tick: reads $OPS_REPO_ROOT/oak/
#   last.json         → last action + key
#   transitions.jsonl → r (last line)
#   weights.json      → Q_ROW (purpose-Q row for the last key)
#
# Contract under test:
#   - no args; OPS_REPO_ROOT unset → exit 2, one-line usage on stderr
#   - last.json missing → exit 0, stdout contains `boot`
#   - stdout is human-readable lines + a `Q_ROW=` line that is one JSON
#     object (the purpose-Q row for last.x_key, or {} if missing)
#   - read-only: never writes weights, never starts organs
# =============================================================================

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STATUS="$ROOT/oak/status.sh"
  OPS="$BATS_TEST_TMPDIR/ops"
  mkdir -p "$OPS/oak"
  export OPS_REPO_ROOT="$OPS"
  cd "$BATS_TEST_TMPDIR" || return 1
}

# --- usage / env -------------------------------------------------------------

@test "OPS_REPO_ROOT unset: exit 2, one-line usage on stderr" {
  run --separate-stderr env -u OPS_REPO_ROOT bash "$STATUS"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [[ "$stderr" == *Usage* ]]
}

@test "arguments given: exit 2 (no-args CLI)" {
  run bash "$STATUS" something
  [ "$status" -eq 2 ]
}

# --- boot ---------------------------------------------------------------------

@test "missing last.json: exit 0, stdout contains boot" {
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"boot"* ]]
  [[ "$output" == *"no last.json"* ]]
}

# --- fixture: last tick + Q row ----------------------------------------------

# write_fixture — last.json (a=dev-poll, x_key=0|1) + a weights table with a
# Q row for that key + one transition line with r=2.
write_fixture() {
  cat >"$OPS/oak/last.json" <<'EOF'
{"x_key":"0|1","a":"dev-poll","x":{"here":1}}
EOF
  cat >"$OPS/oak/weights.json" <<'EOF'
{"q0":1.0,"gvf":{"purpose":{"Q":{"0|1":{"dev-poll":1.5,"idle":0.9}}},"inbound":{"V":{}}}}
EOF
  cat >"$OPS/oak/transitions.jsonl" <<'EOF'
{"t":"2026-01-01T00:00:00Z","x":{"here":1},"a":"dev-poll","r":2,"x2":{"here":1}}
EOF
}

q_row() {
  local line
  line="$(grep '^Q_ROW=' <<<"$1" || true)"
  jq -c . <<<"${line#Q_ROW=}"
}

@test "fixture: prints the last action, key, r, and the Q_ROW object" {
  write_fixture
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-poll"* ]]
  [[ "$output" == *"0|1"* ]]
  [[ "$output" == *"r: 2"* ]]
  local q
  q="$(q_row "$output")"
  [ "$q" = '{"dev-poll":1.5,"idle":0.9}' ]
}

@test "weights.json missing: Q_ROW is {}" {
  cat >"$OPS/oak/last.json" <<'EOF'
{"x_key":"0|1","a":"idle","x":{}}
EOF
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [ "$(q_row "$output")" = '{}' ]
}

@test "no Q row for the last key: Q_ROW is {}" {
  cat >"$OPS/oak/last.json" <<'EOF'
{"x_key":"1|1","a":"idle","x":{}}
EOF
  cat >"$OPS/oak/weights.json" <<'EOF'
{"q0":1.0,"gvf":{"purpose":{"Q":{"0|1":{"idle":0.9}}},"inbound":{"V":{}}}}
EOF
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [ "$(q_row "$output")" = '{}' ]
}

@test "no transitions.jsonl: r is (none)" {
  cat >"$OPS/oak/last.json" <<'EOF'
{"x_key":"0|1","a":"idle","x":{}}
EOF
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"r: (none)"* ]]
}

@test "read-only: weights.json is untouched after a run" {
  write_fixture
  local before after
  before="$(cat "$OPS/oak/weights.json")"
  run bash "$STATUS"
  [ "$status" -eq 0 ]
  after="$(cat "$OPS/oak/weights.json")"
  [ "$before" = "$after" ]
  [ ! -f "$OPS/oak/weights.json.tmp" ]
}
