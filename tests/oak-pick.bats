#!/usr/bin/env bats
# =============================================================================
# tests/oak-pick.bats — unit tests for oak/pick.sh (#1330)
#
# ε-greedy action picker over the oak weights table:
#   oak/pick.sh WEIGHTS.json LEGAL.json
#     LEGAL.json = {"x_key":"2|0","epsilon":0,"q0":1.0,
#                   "legal":["idle","dev-poll","gardener-step"]}
#   Q[x_key][a] missing → q0 (optimistic). stdout: one action name, newline.
#   No exec, no weight updates.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PICK="$ROOT/oak/pick.sh"
  W="$BATS_TEST_TMPDIR/weights.json"
  L="$BATS_TEST_TMPDIR/legal.json"
  # default legal config: epsilon 0, q0 1.0, three actions
  printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":["idle","dev-poll","gardener-step"]}' >"$L"
}

# run_pick <weights-file> <legal-file> — run oak/pick.sh, capture stdout only
# (diagnostics go to stderr and must not pollute the one-line action name).
run_pick() {
  bash "$PICK" "$1" "$2" 2>/dev/null
}

# --- greedy (epsilon = 0) -----------------------------------------------------

@test "epsilon=0: unique max Q picks that action" {
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.3,"dev-poll":0.9,"gardener-step":0.5}}}}}' >"$W"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-poll" ]
}

@test "epsilon=0: ties go to the first action in the legal array" {
  # all missing → all q0 = 1.0 → three-way tie → "idle" (first legal)
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{}}}}' >"$W"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = "idle" ]
}

@test "epsilon=0: several at q0 and one below picks the first q0 action" {
  # dev-poll sits at 0.04; idle and gardener-step read as q0 = 1.0.
  # idle comes first in the legal array and wins the q0 tie.
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"dev-poll":0.04}}}}}' >"$W"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = "idle" ]
}

@test "stdout is exactly one line holding the action name" {
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.3,"dev-poll":0.9,"gardener-step":0.5}}}}}' >"$W"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [ "$output" = "dev-poll" ]
}

# --- q0 fallbacks -------------------------------------------------------------

@test "missing Q[x_key][action] reads as q0 (optimistic)" {
  # only idle is stored at 0.2; dev-poll/gardener-step read as q0 = 1.0
  # → highest is a tie → first in legal that ties is… idle is 0.2, so the
  # q0 tie is dev-poll vs gardener-step → dev-poll (first).
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.2}}}}}' >"$W"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-poll" ]
}

@test "weights file missing is treated as an empty table, not an error" {
  local missing="$BATS_TEST_TMPDIR/absent.json"
  run run_pick "$missing" "$L"
  [ "$status" -eq 0 ]
  # every action reads as q0 → tie → first legal
  [ "$output" = "idle" ]
  [ ! -f "$missing" ]
}

@test "a stored Q of 0 is respected (not treated as missing)" {
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0,"dev-poll":0.9,"gardener-step":0.5}}}}}' >"$W"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-poll" ]
}

# --- read-only contract ---------------------------------------------------------

@test "weights file is not modified by pick.sh" {
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.3,"dev-poll":0.9,"gardener-step":0.5}}},"inbound":{"V":{"2|0":0.4}}}}' >"$W"
  local before after
  before="$(cat "$W")"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  after="$(cat "$W")"
  [ "$before" = "$after" ]
  [ ! -f "$W.tmp" ]
}

# --- exploration (epsilon > 0) --------------------------------------------------

@test "epsilon=1.0: every pick is a legal action" {
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.3,"dev-poll":0.9,"gardener-step":0.5}}}}}' >"$W"
  printf '%s' '{"x_key":"2|0","epsilon":1,"q0":1.0,"legal":["idle","dev-poll","gardener-step"]}' >"$L"
  local i got
  local legal_set=" idle dev-poll gardener-step "
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run run_pick "$W" "$L"
    [ "$status" -eq 0 ]
    got="$output"
    [[ "$legal_set" == *" $got "* ]] || { echo "picked a non-legal action: $got"; false; }
  done
}

@test "epsilon=0.0 picks greedy: no randomness at zero epsilon" {
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.3,"dev-poll":0.9,"gardener-step":0.5}}}}}' >"$W"
  printf '%s' '{"x_key":"2|0","epsilon":0.0,"q0":1.0,"legal":["idle","dev-poll","gardener-step"]}' >"$L"
  local i
  for i in 1 2 3; do
    run run_pick "$W" "$L"
    [ "$status" -eq 0 ]
    [ "$output" = "dev-poll" ]
  done
}

# --- pick.sh does not add idle ---------------------------------------------------

@test "idle is not injected when absent from legal" {
  # Q for idle is the max — but idle is NOT legal, so it must not be picked.
  echo '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":5.0,"dev-poll":0.9,"gardener-step":0.5}}}}}' >"$W"
  printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":["dev-poll","gardener-step"]}' >"$L"
  run run_pick "$W" "$L"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-poll" ]
}

# --- error handling ------------------------------------------------------------

@test "empty legal list exits 2 with a diagnostic on stderr" {
  printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":[]}' >"$L"
  run bash "$PICK" "$W" "$L"
  [ "$status" -eq 2 ]
  [[ "$output" == *"legal list is empty"* ]]
}

@test "missing legal file fails with a diagnostic on stderr" {
  local err rc=0
  err="$(bash "$PICK" "$W" "$BATS_TEST_TMPDIR/nope.json" 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -ne 0 ]
  [[ "$err" == *"legal file not found"* ]]
}

@test "legal JSON with a non-array legal is rejected" {
  printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":"idle"}' >"$L"
  run run_pick "$W" "$L"
  [ "$status" -ne 0 ]
}

@test "legal JSON with a non-numeric epsilon is rejected" {
  printf '%s' '{"x_key":"2|0","epsilon":"high","q0":1.0,"legal":["idle"]}' >"$L"
  run run_pick "$W" "$L"
  [ "$status" -ne 0 ]
}

@test "invalid weights JSON fails with a diagnostic" {
  echo 'not json at all' >"$W"
  local err rc=0
  err="$(bash "$PICK" "$W" "$L" 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -ne 0 ]
  [[ "$err" == *"weights file is not valid JSON"* ]]
}

@test "wrong argument count exits 2" {
  local rc=0
  bash "$PICK" "$W" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}
