#!/usr/bin/env bats
# tests/tape.bats — append-only tape writers (#1389)
#
# lib/tape.sh appends one JSON object per line to $TAPE_DIR/tape.jsonl under
# a single flock; tape_payload content-addresses files into $PAYLOAD_DIR.
# Round-trips every record type, covers validation refusals, lock contention
# (two concurrent writers), payload idempotence, and env overrides.

load '../lib/tape.sh'

setup() {
  TAPE_DIR="$BATS_TEST_TMPDIR/tape"
  PAYLOAD_DIR="$BATS_TEST_TMPDIR/payloads"
  export TAPE_DIR PAYLOAD_DIR
}

# last_record — the most recently appended tape record
last_record() {
  tail -n 1 "$TAPE_DIR/tape.jsonl"
}

# ── proposal ────────────────────────────────────────────────────────────

@test "proposal round-trip: all fields, including optional ones" {
  tape_proposal p-1 dev fix p-0 issue-1389 \
    '{"k":"v","n":1}' '{"p_success":0.7,"est_cost":0.02,"est_dvision":3}' \
    approved '#1389'
  jq -e '
      .type == "proposal"
      and .id == "p-1" and .loop == "dev" and .class == "fix"
      and .parent == "p-0" and .caused_by == "issue-1389"
      and .context == {"k":"v","n":1}
      and .forecast.p_success == 0.7
      and .forecast.est_cost == 0.02
      and .forecast.est_dvision == 3
      and .decision == "approved" and .ref == "#1389"
      and (.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' <(last_record) >/dev/null
}

@test "proposal omits empty parent, caused_by, and forecast" {
  tape_proposal p-2 review fix "" "" '{"a":1}' '' rejected '!42'
  jq -e '.context == {"a":1}
      and .decision == "rejected" and .ref == "!42"
      and ((has("parent") or has("caused_by") or has("forecast")) | not)' \
    <(last_record) >/dev/null
}

@test "proposal refuses context that is not a JSON object" {
  run tape_proposal p-3 dev fix "" '' '"a string"' '' yes r
  [ "$status" -eq 1 ]
  run tape_proposal p-3 dev fix "" '' 'not json' '' yes r
  [ "$status" -eq 1 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

@test "proposal refuses a forecast missing a field or with non-number values" {
  run tape_proposal p-4 dev fix "" '' '{}' '{"p_success":0.5,"est_cost":0.02}' yes r
  [ "$status" -eq 1 ]
  run tape_proposal p-4 dev fix "" '' '{}' '{"p_success":"0.5","est_cost":0.02,"est_dvision":1}' yes r
  [ "$status" -eq 1 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

# ── run ─────────────────────────────────────────────────────────────────

@test "run round-trip" {
  tape_run p-1 dev claude '2026-02-11T00:00:00Z' '2026-02-11T00:10:00Z' \
    2 '{"usd":0.05}' completed
  jq -e '
      .type == "run"
      and .proposal_id == "p-1" and .organ == "dev" and .agent == "claude"
      and .started == "2026-02-11T00:00:00Z" and .ended == "2026-02-11T00:10:00Z"
      and .attempts == 2
      and .cost == {"usd":0.05}
      and .status == "completed"
    ' <(last_record) >/dev/null
}

@test "run refuses an unknown status" {
  run tape_run p-1 dev claude s e 1 '{}' crashed
  [ "$status" -eq 1 ]
}

@test "run refuses non-number attempts and non-object cost" {
  run tape_run p-1 dev claude s e twice '{}' completed
  [ "$status" -eq 1 ]
  run tape_run p-1 dev claude s e 1 '0.05' completed
  [ "$status" -eq 1 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

@test "open run record: empty ENDED+STATUS omit both fields" {
  tape_run p-1 dev claude '2026-02-11T00:00:00Z' '' 1 '{}' ''
  jq -e '
      .type == "run"
      and .proposal_id == "p-1" and .organ == "dev" and .agent == "claude"
      and .started == "2026-02-11T00:00:00Z"
      and .attempts == 1 and .cost == {}
      and (has("ended") | not) and (has("status") | not)
    ' <(last_record) >/dev/null
}

@test "open run record closes by a second append (records are immutable)" {
  tape_run p-1 dev claude '2026-02-11T00:00:00Z' '' 1 '{}' ''
  tape_run p-1 dev claude '2026-02-11T00:00:00Z' '2026-02-11T00:10:00Z' 1 '{}' failed
  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 2 ]
  local open closed
  open="$(sed -n 1p "$TAPE_DIR/tape.jsonl")"
  closed="$(sed -n 2p "$TAPE_DIR/tape.jsonl")"
  jq -ne --argjson o "$open" --argjson c "$closed" '
      ($o | (has("ended") or has("status")) | not)
      and ($c.ended == "2026-02-11T00:10:00Z")
      and ($c.status == "failed")' >/dev/null
}

@test "run refuses a half-closed record (exactly one of ENDED/STATUS)" {
  run tape_run p-1 dev claude s '' 1 '{}' completed
  [ "$status" -eq 2 ]
  run tape_run p-1 dev claude s e 1 '{}' ''
  [ "$status" -eq 2 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

@test "open run record still validates attempts and cost" {
  run tape_run p-1 dev claude s '' twice '{}' ''
  [ "$status" -eq 1 ]
  run tape_run p-1 dev claude s '' 1 '0.05' ''
  [ "$status" -eq 1 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

# ── outcome ─────────────────────────────────────────────────────────────

@test "outcome round-trip" {
  local h
  h="$(printf 'a%.0s' $(seq 64))"
  local payloads
  payloads="[\"$h\"]"
  tape_outcome p-1 '{"ok":true}' '{"sum":3}' '{"n":1}' "$payloads"
  jq -e --arg h "$h" '
      .type == "outcome"
      and .proposal_id == "p-1"
      and .bits == {"ok":true}
      and .numbers == {"sum":3}
      and .children == {"n":1}
      and .payloads == [$h]
    ' <(last_record) >/dev/null
}

@test "outcome refuses non-object bits/numbers/children and bad payloads" {
  local h
  h="$(printf 'a%.0s' $(seq 64))"
  local payloads
  payloads="[\"$h\"]"
  run tape_outcome p-1 '"str"' '{}' '{}' "$payloads"
  [ "$status" -eq 1 ]
  run tape_outcome p-1 '{}' '{}' '[]' "$payloads"
  [ "$status" -eq 1 ]
  run tape_outcome p-1 '{}' '{}' '{}' "[\"nothex\"]"
  [ "$status" -eq 1 ]
  run tape_outcome p-1 '{}' '{}' '{}' '"a64hex"'
  [ "$status" -eq 1 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]

  # An empty payloads array is a valid outcome (no payloads).
  tape_outcome p-1 '{}' '{}' '{}' '[]'
  jq -e '.type == "outcome" and .payloads == []' <(last_record) >/dev/null
}

# ── grade ───────────────────────────────────────────────────────────────

@test "grade round-trip: numeric value" {
  tape_grade p-1 0.8 at_outcome predictor
  jq -e '
      .type == "grade"
      and .proposal_id == "p-1" and .value == 0.8
      and .when == "at_outcome" and .who == "predictor"
    ' <(last_record) >/dev/null
}

@test "grade accepts a null value" {
  tape_grade p-1 null at_approval human
  jq -e '.type == "grade" and .value == null and .when == "at_approval"' \
    <(last_record) >/dev/null
}

@test "grade refuses a bad when and a non-numeric value" {
  run tape_grade p-1 1 maybe someone
  [ "$status" -eq 1 ]
  run tape_grade p-1 'high' at_outcome 'someone else'
  [ "$status" -eq 1 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

# ── payload ─────────────────────────────────────────────────────────────

@test "payload: content-addressed copy, idempotent, echoes the hash" {
  local f="$BATS_TEST_TMPDIR/data.txt"
  echo "payload body" > "$f"
  local expected
  expected="$(sha256sum "$f" | cut -d' ' -f1)"

  local h1 h2
  h1="$(tape_payload "$f")"
  h2="$(tape_payload "$f")"
  [ "$h1" = "$expected" ]
  [ "$h2" = "$expected" ]
  [ -f "$PAYLOAD_DIR/$h1" ]
  diff "$f" "$PAYLOAD_DIR/$h1"

  # A different file lands under a different name.
  local g="$BATS_TEST_TMPDIR/other.txt"
  echo "other body" > "$g"
  local h3
  h3="$(tape_payload "$g")"
  [ "$h3" != "$h1" ]
  [ -f "$PAYLOAD_DIR/$h3" ]
}

@test "payload refuses a missing file" {
  run tape_payload "$BATS_TEST_TMPDIR/no-such-file"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a regular file"* ]]
}

# ── storage / locking ───────────────────────────────────────────────────

@test "TAPE_DIR and PAYLOAD_DIR are env-overridable" {
  export TAPE_DIR="$BATS_TEST_TMPDIR/elsewhere/tape"
  export PAYLOAD_DIR="$BATS_TEST_TMPDIR/elsewhere/payloads"
  tape_proposal p-9 dev fix '' '' '{}' '' yes r
  [ -f "$TAPE_DIR/tape.jsonl" ]
  local f="$BATS_TEST_TMPDIR/p.txt"
  echo body > "$f"
  local h
  h="$(tape_payload "$f")"
  [ -f "$PAYLOAD_DIR/$h" ]
}

@test "defaults are /srv/disinto/tape and /srv/disinto/payloads" {
  run bash -c "unset TAPE_DIR PAYLOAD_DIR; source '$BATS_TEST_DIRNAME/../lib/tape.sh'; echo \"\$TAPE_DIR \$PAYLOAD_DIR\""
  [ "$status" -eq 0 ]
  [ "$output" = "/srv/disinto/tape /srv/disinto/payloads" ]
}

@test "two concurrent writers: no lost or interleaved records" {
  local w i
  for w in 1 2; do
    (
      for i in $(seq 50); do
        tape_run "p-1" dev "agent-$w" s e 1 '{}' completed
      done
    ) &
  done
  wait

  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 100 ]
  # Every line must parse and be a run record (jq -s fails on any torn line).
  jq -es 'length == 100 and (map(.type == "run") | all)' \
    "$TAPE_DIR/tape.jsonl" >/dev/null
}
