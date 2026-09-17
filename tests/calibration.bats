#!/usr/bin/env bats
# tests/calibration.bats — tools/calibration.sh (#1393)
#
# calibration.sh reads $TAPE_DIR/tape.jsonl, pairs each proposal with its
# LAST outcome record (in tape order), groups the pairs by (loop, class),
# and prints a markdown calibration table: n, merged rate (outcome
# bits.merged true/1), mean duration_s (outcome numbers.duration_s, missing
# ones skipped). Pure bash + jq; the tape is only read, never written.

TOOL="$BATS_TEST_DIRNAME/../tools/calibration.sh"

setup() {
  TAPE_DIR="$BATS_TEST_TMPDIR/tape"
  export TAPE_DIR
  mkdir -p "$TAPE_DIR"
}

# header_only — the whole output is the header row and its separator.
header_only() {
  [ "$output" = $'| loop | class | n | merged rate | mean duration_s |\n|---|---|---|---|---|' ]
}

# write_fixture_tape — the AC fixture: 3 pairs across 2 classes, plus
# records that must not form pairs: a run record, an orphan outcome, and a
# proposal without any outcome.
write_fixture_tape() {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#1"}
{"type":"run","t":"2026-02-01T00:00:01Z","proposal_id":"p-1","organ":"dev","agent":"claude","started":"2026-02-01T00:00:01Z","ended":"2026-02-01T00:01:40Z","attempts":1,"cost":{"usd":0.01},"status":"completed"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#2"}
{"type":"outcome","t":"2026-02-02T00:00:30Z","proposal_id":"p-2","bits":{"merged":0},"numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-03T00:00:00Z","id":"p-3","loop":"review","class":"docs","context":{},"decision":"approved","ref":"#3"}
{"type":"outcome","t":"2026-02-03T00:02:00Z","proposal_id":"p-3","bits":{"merged":true},"numbers":{"duration_s":300},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-04T00:00:00Z","proposal_id":"p-orphan","bits":{"merged":1},"numbers":{"duration_s":5},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-05T00:00:00Z","id":"p-4","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#4"}
EOF
}

@test "missing tape: header row only, exit 0" {
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  header_only
}

@test "empty tape: header row only, exit 0" {
  : > "$TAPE_DIR/tape.jsonl"
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  header_only
}

@test "3 pairs across 2 classes: full calibration table" {
  write_fixture_tape
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [ "$output" = $'| loop | class | n | merged rate | mean duration_s |\n|---|---|---|---|---|\n| dev | fix | 2 | 50% | 100.0 |\n| review | docs | 1 | 100% | 300.0 |' ]
}

@test "the tape is only read, never written" {
  write_fixture_tape
  local before after
  before="$(md5sum "$TAPE_DIR/tape.jsonl")"
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  after="$(md5sum "$TAPE_DIR/tape.jsonl")"
  [ "$before" = "$after" ]
}

@test "group with no durations: mean duration_s is -" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-1","bits":{},"numbers":{},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| dev | fix | 1 | 0% | - |"* ]]
}

@test "rows sorted by loop then class" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"a","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#a"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"a","bits":{"merged":1},"numbers":{"duration_s":10},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:00:00Z","id":"b","loop":"dev","class":"docs","context":{},"decision":"approved","ref":"#b"}
{"type":"outcome","t":"2026-02-02T00:01:00Z","proposal_id":"b","bits":{"merged":0},"numbers":{"duration_s":20},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-03T00:00:00Z","id":"c","loop":"planner","class":"plan","context":{},"decision":"approved","ref":"#c"}
{"type":"outcome","t":"2026-02-03T00:01:00Z","proposal_id":"c","bits":{"merged":true},"numbers":{"duration_s":30},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  local rows
  rows="$(printf '%s\n' "$output" | grep -v '^|---' | tail -n +2)"
  [ "$rows" = $'| dev | docs | 1 | 0% | 20.0 |\n| dev | fix | 1 | 100% | 10.0 |\n| planner | plan | 1 | 100% | 30.0 |' ]
}

@test "the last outcome per proposal is the pair (session-end precedes terminal)" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-1","bits":{"exit_ok":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T02:00:00Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":120},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| dev | fix | 1 | 100% | 120.0 |"* ]]
}

@test "duration missing on the last outcome: mean is -, never the earlier one" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-1","bits":{"exit_ok":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T02:00:00Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| dev | fix | 1 | 100% | - |"* ]]
}

@test "malformed line is skipped with a stderr note, not fatal" {
  write_fixture_tape
  echo 'not json' >> "$TAPE_DIR/tape.jsonl"
  local out err
  out="$(bash "$TOOL" 2>"$BATS_TEST_TMPDIR/err")"
  [[ "$out" == *"| dev | fix | 2 | 50% | 100.0 |"* ]]
  [[ "$out" == *"| review | docs | 1 | 100% | 300.0 |"* ]]
  grep -q 'skipped 1 malformed line' "$BATS_TEST_TMPDIR/err"
}

@test "defaults TAPE_DIR to /srv/disinto/tape" {
  # The live tape cannot be asserted on (CI has none), but the run must
  # resolve the default, exit 0, and open with the header row.
  run env -u TAPE_DIR bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| loop | class | n | merged rate | mean duration_s |"* ]]
  [[ "$output" == *"|---|---|---|---|---|"* ]]
}
