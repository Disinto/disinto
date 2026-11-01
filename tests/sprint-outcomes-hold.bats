#!/usr/bin/env bats
# tests/sprint-outcomes-hold.bats — tools/sprint-outcomes.sh writes nothing
# while ${TAPE_DIR}/sprints/HOLD exists: a hold set by hand when the effect
# probes would read the wrong window.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  CALLS="$BATS_TEST_TMPDIR/calls"
  TAPE_DIR="$BATS_TEST_TMPDIR/tape"
  mkdir -p "$STUB_BIN" "$FIXTURES" "$TAPE_DIR/sprints"
  : >"$CALLS"
  # shellcheck source=lib/forge-stub.sh
  source "$ROOT/tests/lib/forge-stub.sh"
  stub_milestone_forge_api
  # Sprint 1: closed, effect none, no soak, one merged child: due at once.
  write_milestone 1 closed 0 1 "class: internal
effect: none
expect: >= 1
soak: 0h"
  printf '%s\n' "s-1" >"$TAPE_DIR/sprints/1"
  jq -cn '{type: "proposal", t: "2026-02-10T00:00:00Z", id: "c1",
           loop: "dev", class: "internal", parent: "s-1", context: {},
           decision: "approved", ref: "x"}' >"$TAPE_DIR/tape.jsonl"
  jq -cn '{type: "outcome", t: "2026-02-10T01:00:00Z", proposal_id: "c1",
           bits: {merged: 1}, numbers: {}, children: {}, payloads: []}' \
    >>"$TAPE_DIR/tape.jsonl"
}

run_tool() {
  run env -u FORGE_API -u FORGE_TOKEN TAPE_DIR="$TAPE_DIR" \
    PATH="$STUB_BIN:$PATH" FORGE_CALLS="$CALLS" FORGE_FIXTURES="$FIXTURES" \
    bash "$ROOT/tools/sprint-outcomes.sh"
}

@test "without a hold, a due sprint gets its outcome" {
  run_tool
  [ "$status" -eq 0 ]
  jq -es 'map(select(.type == "outcome" and .proposal_id == "s-1")) | length == 1' \
    "$TAPE_DIR/tape.jsonl" >/dev/null
  [ -e "$TAPE_DIR/sprints/1.done" ]
}

@test "with a hold, nothing is read or written" {
  : >"$TAPE_DIR/sprints/HOLD"
  cp "$TAPE_DIR/tape.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  run_tool
  [ "$status" -eq 0 ]
  [[ "$output" == *"on hold"* ]]
  cmp -s "$TAPE_DIR/tape.jsonl" "$BATS_TEST_TMPDIR/before.jsonl"
  [ ! -e "$TAPE_DIR/sprints/1.done" ]
  [ ! -s "$CALLS" ]
}
