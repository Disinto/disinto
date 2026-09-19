#!/usr/bin/env bats
# tests/grade.bats — tools/grade.sh (#1410)
#
# grade.sh appends one grade record to $TAPE_DIR/tape.jsonl via
# lib/tape.sh (#1389): who = $USER, when defaults to at_outcome. It prints
# the appended line on stdout; missing args or a non-float value print
# usage on stderr and exit 64.

TOOL="$BATS_TEST_DIRNAME/../tools/grade.sh"

setup() {
  TAPE_DIR="$BATS_TEST_TMPDIR/tape"
  USER="${USER:-grade-tester}"
  export TAPE_DIR USER
  mkdir -p "$TAPE_DIR"
}

# fixture_proposal — the proposal record the grade attaches to.
fixture_proposal() {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#1410"}
EOF
}

@test "grading a fixture proposal appends a well-formed grade line and prints it" {
  fixture_proposal
  run bash "$TOOL" p-1 0.85
  [ "$status" -eq 0 ]
  # stdout is exactly the appended line, which is the tape's last line.
  [ "$output" = "$(tail -n 1 "$TAPE_DIR/tape.jsonl")" ]
  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 2 ]
  jq -e --arg who "$USER" '
    .type == "grade"
    and .proposal_id == "p-1"
    and (.value | type) == "number"
    and .value == 0.85
    and .when == "at_outcome"
    and .who == $who
    and (.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' <(printf '%s\n' "$output") >/dev/null
}

@test "explicit when is recorded; negative and .5-style floats accepted" {
  fixture_proposal
  run bash "$TOOL" p-1 1 at_approval
  [ "$status" -eq 0 ]
  jq -e '.type == "grade" and .value == 1 and .when == "at_approval"' \
    <(printf '%s\n' "$output") >/dev/null

  run bash "$TOOL" p-1 -0.5
  [ "$status" -eq 0 ]
  jq -e '.value == -0.5' <(printf '%s\n' "$output") >/dev/null

  run bash "$TOOL" p-1 .25
  [ "$status" -eq 0 ]
  jq -e '.value == 0.25' <(printf '%s\n' "$output") >/dev/null
  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 4 ]
}

# run_grading <args...> — run the tool with stdout/stderr captured to files,
# leaving the exit code in RC and the bodies in $OUT / $ERR.
OUT="$BATS_TEST_TMPDIR/out"
ERR="$BATS_TEST_TMPDIR/err"
RC=0
run_grading() {
  RC=0
  bash "$TOOL" "$@" > "$OUT" 2> "$ERR" || RC=$?
}

@test "non-float value: usage on stderr, exit 64, nothing appended" {
  fixture_proposal
  run_grading p-1 high
  [ "$RC" -eq 64 ]
  grep -q "usage:" "$ERR"
  grep -q "<float>" "$ERR"
  [ -z "$(cat "$OUT")" ]
  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 1 ]

  run_grading p-1 0.5.1
  [ "$RC" -eq 64 ]
  run_grading p-1 ""
  [ "$RC" -eq 64 ]
}

@test "missing args: usage on stderr, exit 64" {
  run_grading
  [ "$RC" -eq 64 ]
  grep -q "usage:" "$ERR"
  grep -q "<proposal-id>" "$ERR"
  [ ! -e "$TAPE_DIR/tape.jsonl" ]

  run_grading p-1
  [ "$RC" -eq 64 ]
  grep -q "usage:" "$ERR"
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

@test "unknown when: usage on stderr, exit 64" {
  fixture_proposal
  run_grading p-1 0.5 mid_flight
  [ "$RC" -eq 64 ]
  grep -q "at_approval|at_outcome" "$ERR"
  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 1 ]
}

@test "under concurrent tape writes the printed line is always grade.sh's own record" {
  fixture_proposal
  local stop="$BATS_TEST_TMPDIR/stop"
  local lib="$BATS_TEST_DIRNAME/../lib/tape.sh"

  # Background writer hammering the same tape (the natural race: an organ
  # session ending while at_outcome grading lands on the same tape).
  (
    # shellcheck disable=SC1091
    source "$lib"
    while [ ! -e "$stop" ]; do
      tape_run w-1 dev background-writer s e 1 '{}' completed
    done
  ) >/dev/null 2>&1 &
  local writer=$!

  local i line
  for i in $(seq 1 30); do
    line="$(bash "$TOOL" p-1 0.85)"
    jq -e --arg who "$USER" '
      .type == "grade"
      and .proposal_id == "p-1"
      and .value == 0.85
      and .when == "at_outcome"
      and .who == $who
    ' <(printf '%s\n' "$line") >/dev/null || {
      touch "$stop"
      wait "$writer"
      return 1
    }
  done
  touch "$stop"
  wait "$writer"
}
