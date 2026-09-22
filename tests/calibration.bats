#!/usr/bin/env bats
# tests/calibration.bats — tools/calibration.sh (#1393, extended #1451, #1473)
#
# calibration.sh reads $TAPE_DIR/tape.jsonl, pairs each proposal with its
# LAST outcome record (in tape order), drops non-sample pairs, and groups
# the rest by (loop, class) as a markdown table:
#
#   | loop | class | n | promised | actual | error | mean duration_s |
#
#   - n               number of sample pairs in the group
#   - promised        mean of the proposals' forecast.p_success (integer
#                     percent) over the sample pairs that carry a numeric one
#                     (forecast lands on the proposal record, #1451);
#                     "-" when no sample pair in the group carries one
#   - actual          share of sample pairs whose last outcome carries the
#                     loop's own competence bit true/1, integer percent:
#                       dev -> bits.merged, repair -> bits.regression_cleared
#   - error           |promised - actual| in percentage points when promised
#                     is present; "-" otherwise
#   - mean duration_s mean of sample pairs' outcome numbers.duration_s over
#                     the pairs that carry one (missing ones skipped, never
#                     counted as zero); "-" when no pair in the group
#                     carries one
#
# A pair is a sample only when the loop is dev or repair and the LAST
# outcome carries that loop's competence bit (true/false/1/0): true/1 is a
# success, false/0 a failure. Any other loop, or a last outcome without the
# bit, is dropped from n, promised, actual, and mean duration_s (never
# counted as 0%).
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

# write_fixture_tape — 3 sampled pairs across 2 loops, plus records that must
# not form pairs: a run record, an orphan outcome, and a proposal without any
# outcome. (No forecasts: old-tape rows still calibrate, with
# promised/error shown as "-".)
write_fixture_tape() {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-2","bits":{"merged":0},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-3","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"3"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-3","bits":{"regression_cleared":1},"numbers":{"duration_s":50},"children":{},"payloads":[]}
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

@test "3 sampled pairs across 2 loops: full calibration table" {
  write_fixture_tape
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # p-1 merged, p-2 not -> dev/fix n=2, actual 50%, mean 100.0 (p-2 has no
  # duration); p-3 regression_cleared -> repair/incident n=1, 100%,
  # mean 50.0
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | fix | 2 | - | 50% | - | 100.0 |\n| repair | incident | 1 | - | 100% | - | 50.0 |' ]
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
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-2","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-2","bits":{"regression_cleared":1},"numbers":{"duration_s":30},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-3","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"3"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-3","bits":{"merged":1},"numbers":{"duration_s":10},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-4","loop":"review","class":"docs","context":{},"decision":"approved","ref":"4"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-4","bits":{"merged":1},"numbers":{"duration_s":999},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # p-4 (review) is never a sample: only dev + repair rows print, sorted
  # dev/docs, dev/fix, repair/incident
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | docs | 1 | - | 0% | - | 20.0 |\n| dev | fix | 1 | - | 100% | - | 10.0 |\n| repair | incident | 1 | - | 100% | - | 30.0 |' ]
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

@test "last outcome without the bit is not a sample" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":40},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T00:02:00Z","proposal_id":"p-1","bits":{"exit_ok":0},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # Same last-outcome pairing: the last outcome has no merged bit, so the
  # pair is dropped entirely (never counted as 0%)
  header_only
}

@test "only non-sample pairs: header row only, exit 0" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-1","bits":{"merged":1}}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"f-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"f-1","bits":{"exit_ok":1}}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"v-1","loop":"review","class":"docs","context":{},"decision":"approved","ref":"3"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"v-1","bits":{"merged":1}}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # repair pair carries merged only (no regression_cleared), dev pair
  # carries exit_ok only (no merged), review pair has no competence bit at
  # all: no samples -> header row only
  header_only
}

@test "repair: regression_cleared decides, never 0% for a missing merged bit" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-1","bits":{"regression_cleared":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-2","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-2","bits":{"merged":1},"numbers":{"duration_s":200},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # r-2 carries merged:1 but no regression_cleared -> not a sample: n=1
  # (never 2, so never 50%/0%), mean 100.0 (not 150.0)
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| repair | incident | 1 | - | 100% | - | 100.0 |' ]
}

@test "repair: regression_cleared 0 counts as a failure" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-1","bits":{"regression_cleared":0},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # bit present (0) -> counted in n as a failure
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| repair | incident | 1 | - | 0% | - | - |' ]
}

@test "dev: 10 merged plus 6 exit_ok-only outcomes are not samples" {
  {
    for i in 1 2 3 4 5 6 7 8 9 10; do
      printf '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"d-%s","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1473-d%s"}\n' "$i" "$i"
      printf '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"d-%s","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}\n' "$i"
    done
    for i in 1 2 3 4 5 6; do
      printf '{"type":"proposal","t":"2026-02-01T00:02:00Z","id":"f-%s","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1473-f%s"}\n' "$i" "$i"
      printf '{"type":"outcome","t":"2026-02-01T00:02:01Z","proposal_id":"f-%s","bits":{"exit_ok":1},"numbers":{"duration_s":999},"children":{},"payloads":[]}\n' "$i"
    done
  } > "$TAPE_DIR/tape.jsonl"
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # only the 10 merged outcomes count: n=10, actual=100%, mean over the 10
  # samples only (the 999-s exit_ok durations are excluded)
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | fix | 10 | - | 100% | - | 100.0 |' ]
}

@test "true/false bits count as success/failure" {
  cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"d-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"d-1","bits":{"merged":true},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"d-2","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"d-2","bits":{"merged":false},"numbers":{"duration_s":50},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"3"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-1","bits":{"regression_cleared":false},"numbers":{"duration_s":10},"children":{},"payloads":[]}
EOF
  run bash "$TOOL"
  [ "$status" -eq 0 ]
  # true/false are valid bit values: 1/2 merged, 0/1 cleared -> 50%/0%
  [ "$output" = $'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|\n| dev | fix | 2 | - | 50% | - | 75.0 |\n| repair | incident | 1 | - | 0% | - | 10.0 |' ]
}

@test "malformed line is skipped with stderr note" {
  write_fixture_tape
  printf 'not json {\n' >> "$TAPE_DIR/tape.jsonl"
  run bash "$TOOL" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *'| dev | fix | 2 | - | 50% | - | 100.0 |'* ]]
  [[ "$output" == *'| repair | incident | 1 | - | 100% | - | 50.0 |'* ]]
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
  # only p-1 carries a numeric p_success -> promised = 50%; p-2 still
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
