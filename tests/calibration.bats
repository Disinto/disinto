#!/usr/bin/env bats
# tests/calibration.bats — tools/calibration.sh (#1393, extended #1451)
#
# calibration.sh reads $TAPE_DIR/tape.jsonl, pairs each proposal with its
# LAST outcome record (in tape order), groups the pairs by (loop, class),
# and prints a markdown calibration table:
#
#   | loop | class | n | promised | actual | error | mean duration_s |
#
#   - n               pairs in the group
#   - promised        mean of the proposals' forecast.p_success (integer
#                     percent) over the pairs that carry a numeric one
#                     (forecast lands on the proposal record, #1451);
#                     "-" when no pair in the group carries one
#   - actual          share of pairs with outcome bits.merged true/1,
#                     integer percent
#   - error           |promised - actual| in percentage points when
#                     promised is present; "-" otherwise
#   - mean duration_s mean of pairs' outcome numbers.duration_s over the
#                     pairs that carry one (missing ones skipped, never
#                     counted as zero); "-" when no pair in the group
#                     carries one
#
# Pure bash + jq; the tape is only read, never written.

TOOL="$BATS_TEST_DIRNAME/../tools/calibration.sh"

setup() {
  TAPE_DIR="$BATS_TEST_TMPDIR/tape"
  export TAPE_DIR
  mkdir -p "$TAPE_DIR"
}

# header_only — the whole output is the header row and its separator.
header_only() {
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|' ]
}

# write_fixture_tape — the AC fixture: 3 pairs across 2 classes, plus
# records that must not form pairs: a run record, an orphan outcome, and a
# proposal without any outcome. (No forecasts: old-tape rows still
# calibrate, with promised/error shown as "-".)
write_fixture_tape() {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-2","bits":{"merged":0},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-3","loop":"review","class":"docs","context":{},"decision":"approved","ref":"3"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-3","bits":{"merged":1},"numbers":{"duration_s":300},"children":{},"payloads":[]}
{"type":"run","t":"2026-02-01T00:02:00Z","proposal_id":"p-1"}
{"type":"outcome","t":"2026-02-01T00:02:00Z","proposal_id":"p-orphan","bits":{"merged":1}}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-4","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"4"}
EOF
}

@test "missing tape: header row only, exit 0" {
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  header_only
}

@test "empty tape: header row only, exit 0" {
  touch "$TAPE_DIR/tape.jsonl"
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  header_only
}

@test "3 pairs across 2 classes: full calibration table" {
  write_fixture_tape
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # p-1 merged, p-2 not → dev/fix n=2, actual 50%; p-3 merged → 100%
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | fix | 2 | - | 50% | - | 100.0 |\n| review | docs | 1 | - | 100% | - | 300.0 |' ]
}

@test "group with no durations: mean duration_s is -" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":0},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| dev | fix | 1 | - | 0% | - | - |'* ]]
}

@test "rows sorted by loop then class" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"docs","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-1","bits":{"merged":0},"numbers":{"duration_s":20},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-2","loop":"planner","class":"plan","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-2","bits":{"merged":1},"numbers":{"duration_s":30},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-3","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"3"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-3","bits":{"merged":1},"numbers":{"duration_s":10},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | docs | 1 | - | 0% | - | 20.0 |\n| dev | fix | 1 | - | 100% | - | 10.0 |\n| planner | plan | 1 | - | 100% | - | 30.0 |' ]
}

@test "last outcome per proposal wins" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":0},"numbers":{"duration_s":40},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T00:02:00Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":120},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| dev | fix | 1 | - | 100% | - | 120.0 |'* ]]
}

@test "duration missing on last outcome: mean is -" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":40},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T00:02:00Z","proposal_id":"p-1","bits":{"merged":1},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| dev | fix | 1 | - | 100% | - | - |'* ]]
}

@test "malformed line is skipped with stderr note" {
  write_fixture_tape
  printf 'not json {\n' >> "$TAPE_DIR/tape.jsonl"
  run bash "$TOOL" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *'| dev | fix | 2 | - | 50% | - | 100.0 |'* ]]
  [[ "$output" == *'| review | docs | 1 | - | 100% | - | 300.0 |'* ]]
  [[ "$output" == *'skipped 1 malformed line(s)'* ]]
}

@test "fixture with forecasts: promised/actual/error print as percents" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"#1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.7,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"#2"}
{"type":"outcome","t":"2026-02-02T00:00:30Z","proposal_id":"p-2","bits":{"merged":0},"numbers":{"duration_s":50},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # promised mean(0.5, 0.7) = 60%, actual 50% (1/2 merged), error |60-50| = 10
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | fix | 2 | 60% | 50% | 10 | 75.0 |' ]
}

@test "forecast on only some pairs: mean over the numeric ones only" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"#1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"#2"}
{"type":"outcome","t":"2026-02-02T00:00:30Z","proposal_id":"p-2","bits":{"merged":0},"numbers":{"duration_s":50},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # only p-1 carries a numeric p_success → promised = 50%; p-2 still
  # counts in n and actual, so pairs without a forecast are not dropped
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | fix | 2 | 50% | 50% | 0 | 75.0 |' ]
}

@test "defaults TAPE_DIR to /srv/disinto/tape (header path only, no writes)" {
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| loop | class | n | promised | actual | error | mean duration_s |'* ]]
  [[ "$output" == *'|---|---|---|---|---|---|---|'* ]]
}

@test "tape file is not modified by a run" {
  write_fixture_tape
  before="$(md5sum "$TAPE_DIR/tape.jsonl" | awk '{print $1}')"
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  after="$(md5sum "$TAPE_DIR/tape.jsonl" | awk '{print $1}')"
  [ "$before" = "$after" ]
}