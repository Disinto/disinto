#!/usr/bin/env bats
# tests/lib-formula-tape.bats — proposal-loop tape instrumentation (#1391)
#
# lib/formula-session.sh brackets a formula session with
# formula_session_start / formula_session_end: an OPEN tape_run line (started,
# attempts, ended/status omitted) and a closing tape_run (ended + status
# completed|failed, session cost on the run's cost object: duration_s +
# tokens_in/tokens_out from the transcript's final usage row + transcript
# payload ref) — records are immutable, so the close is a second append.
# No tape_outcome is written (#1474): run status lives on the run record, not
# on a separate outcome. The functions are total: every tape failure logs a
# WARNING and returns 0, so an unwritable TAPE_DIR can never fail the organ.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TAPE_DIR="$BATS_TEST_TMPDIR/tape"
  PAYLOAD_DIR="$BATS_TEST_TMPDIR/payloads"
  export ROOT TAPE_DIR PAYLOAD_DIR
  # Control the environment: the default organs key on their own run ULID,
  # so an inherited TAPE_PROPOSAL_ID (a caller-supplied proposal) would
  # append a spurious proposal record. Tests that need a caller proposal
  # export their own inside the driver.
  unset TAPE_PROPOSAL_ID
}

# write_driver — drop a driver script (inheriting ROOT/TAPE_DIR/PAYLOAD_DIR)
# and run it under set -euo pipefail, like the organ runners do.
write_driver() {
  cat > "$BATS_TEST_TMPDIR/drv.sh"
  run bash "$BATS_TEST_TMPDIR/drv.sh"
}

@test "formula_tape_ulid emits 26-char Crockford base32 ULIDs" {
  write_driver <<'EOF'
set -euo pipefail
log() { :; }
source "$ROOT/lib/formula-session.sh"
printf '%s\n' "$(formula_tape_ulid)"
printf '%s\n' "$(formula_tape_ulid)"
EOF
  [ "$status" -eq 0 ]
  local a b
  a="$(printf '%s\n' "$output" | sed -n 1p)"
  b="$(printf '%s\n' "$output" | sed -n 2p)"
  [[ "$a" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
  [[ "$b" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
  [ "$a" != "$b" ]
}

@test "formula_session_end without a start is a no-op" {
  write_driver <<'EOF'
set -euo pipefail
log() { :; }
source "$ROOT/lib/formula-session.sh"
formula_session_end 0
formula_session_end 1
echo OK
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
}

@test "start→end: open run, closing run with cost; payload + tokens from transcript" {
  local t="$BATS_TEST_TMPDIR/transcript.json"
  printf '%s\n' \
    '{"type":"assistant","message":{"id":"m1"}}' \
    '{"type":"result","subtype":"success","usage":{"input_tokens":123,"output_tokens":45}}' \
    > "$t"
  write_driver <<EOF
set -euo pipefail
log() { printf 'WARN %s\n' "\$*" >&2; }
export AGENT_HARNESS=claude CLAUDE_MODEL=opus LOG_AGENT=testorgan
source "\$ROOT/lib/formula-session.sh"
formula_session_start "testorgan"
sleep 1
formula_session_end 0 "$t"
EOF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$TAPE_DIR/tape.jsonl")" -eq 2 ]
  jq -es '
      (length == 2)
      and (.[0].type == "run")
      and ((.[0] | has("ended")) | not)
      and ((.[0] | has("status")) | not)
      and (.[0].organ == "testorgan")
      and (.[0].agent == "claude/opus")
      and (.[0].attempts == 1)
      and (.[0].cost == {})
      and (.[0].proposal_id | test("^[0-9A-HJKMNP-TV-Z]{26}$"))
      and (.[0].started | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (.[1].type == "run")
      and (.[1].proposal_id == .[0].proposal_id)
      and (.[1].started == .[0].started)
      and ((.[1].cost.duration_s | type) == "number")
      and (.[1].cost.duration_s >= 1)
      and (.[1].cost.tokens_in == 123)
      and (.[1].cost.tokens_out == 45)
      and (.[1].ended | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (.[1].status == "completed")
      and (.[1].attempts == 1)
    ' "$TAPE_DIR/tape.jsonl" >/dev/null
  local h
  h="$(sha256sum "$t" | cut -d' ' -f1)"
  jq -es --arg h "$h" -e '.[1].cost.transcript == $h' "$TAPE_DIR/tape.jsonl" >/dev/null
  [ -f "$PAYLOAD_DIR/$h" ]
  diff "$t" "$PAYLOAD_DIR/$h"
}

@test "non-zero exit code → status failed, no outcome" {
  write_driver <<'EOF'
set -euo pipefail
log() { :; }
source "$ROOT/lib/formula-session.sh"
formula_session_start "testorgan"
formula_session_end 124
EOF
  [ "$status" -eq 0 ]
  jq -es '
      (length == 2)
      and ((map(select(.type == "outcome")) | length) == 0)
      and (.[1].status == "failed")
      and ((.[1].cost.duration_s | type) == "number")
    ' "$TAPE_DIR/tape.jsonl" >/dev/null
}

@test "missing transcript → no transcript key, no token fields, agent without model" {
  write_driver <<EOF
set -euo pipefail
log() { printf 'WARN %s\n' "\$*" >&2; }
export AGENT_HARNESS=claude LOG_AGENT=testorgan
unset CLAUDE_MODEL
source "\$ROOT/lib/formula-session.sh"
formula_session_start "testorgan"
formula_session_end 0 "$BATS_TEST_TMPDIR/absent.json"
EOF
  [ "$status" -eq 0 ]
  jq -es '
      (.[0].agent == "claude")
      and ((.[1].cost | has("tokens_in")) | not)
      and ((.[1].cost | has("tokens_out")) | not)
      and ((.[1].cost | has("transcript")) | not)
      and ((.[1].cost.duration_s | type) == "number")
      and (.[1].status == "completed")
    ' "$TAPE_DIR/tape.jsonl" >/dev/null
}

@test "TAPE_PROPOSAL_ID: minimal proposal appended once when unknown" {
  write_driver <<'EOF'
set -euo pipefail
log() { :; }
export TAPE_PROPOSAL_ID=prop-42
source "$ROOT/lib/formula-session.sh"
formula_session_start "planner"
formula_session_end 0
EOF
  [ "$status" -eq 0 ]
  jq -es '
      (length == 3)
      and (.[0].type == "proposal")
      and (.[0].id == "prop-42")
      and (.[0].loop == "formula")
      and (.[0].decision == "auto")
      and (.[0].ref == "prop-42")
      and (.[0].context.organ == "planner")
      and ((map(select(.type == "proposal")) | length) == 1)
      and (.[1].type == "run")
      and (.[1].proposal_id == "prop-42")
      and ((map(select(.type == "outcome")) | length) == 0)
      and (.[2].type == "run")
    ' "$TAPE_DIR/tape.jsonl" >/dev/null
}

@test "TAPE_PROPOSAL_ID: existing proposal record is not re-appended" {
  write_driver <<'EOF'
set -euo pipefail
log() { :; }
export TAPE_PROPOSAL_ID=prop-9
source "$ROOT/lib/formula-session.sh"
tape_proposal prop-9 review fix '' '' '{}' '' approved r
formula_session_start "planner"
formula_session_end 0
EOF
  [ "$status" -eq 0 ]
  jq -es '
      (length == 3)
      and (.[0].type == "proposal" and .[0].loop == "review")
      and ((map(select(.type == "proposal")) | length) == 1)
      and (.[1].proposal_id == "prop-9")
      and ((map(select(.type == "outcome")) | length) == 0)
      and (.[2].type == "run")
    ' "$TAPE_DIR/tape.jsonl" >/dev/null
}

@test "double end appends a single closing run (idempotent close)" {
  write_driver <<'EOF'
set -euo pipefail
log() { :; }
source "$ROOT/lib/formula-session.sh"
formula_session_start "testorgan"
formula_session_end 0
formula_session_end 0
EOF
  [ "$status" -eq 0 ]
  jq -es '
      (length == 2)
      and ((map(select(.type == "outcome")) | length) == 0)
      and ((map(select(.type == "run")) | length) == 2)
    ' "$TAPE_DIR/tape.jsonl" >/dev/null
}

@test "unwritable TAPE_DIR: start and end still return 0 (organ never fails)" {
  # A regular file blocks mkdir of the tape dir even as root.
  touch "$BATS_TEST_TMPDIR/blocker"
  TAPE_DIR="$BATS_TEST_TMPDIR/blocker/tape"
  export TAPE_DIR
  write_driver <<'EOF'
set -euo pipefail
log() { printf 'WARN %s\n' "$*" >&2; }
source "$ROOT/lib/formula-session.sh"
formula_session_start "testorgan"
formula_session_end 1
EOF
  [ "$status" -eq 0 ]
  [ ! -e "$TAPE_DIR/tape.jsonl" ]
  [[ "$output" == *WARNING*tape* ]]
}
