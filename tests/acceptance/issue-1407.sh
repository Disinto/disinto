#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1407.sh
#
# Issue #1407: the edge dispatcher records every approved vault action on
# the tape (lib/tape.sh):
#
#   fire (launch_runner):
#     tape_proposal <action-id> production "<TOML formula>" "" "" \
#       '{"target":"<host>"}' "" "approved" "<action-id>"
#
#   result observed (commit_result_via_git, right after the result JSON is
#   written):
#     tape_outcome <action-id> '{"returned":1,"ok":0|1}' \
#       '{"duration_s":<n>}' '{}' [<sha256 of the result file>]
#
# A tape failure must warn and continue — dispatch is never blocked by the
# tape (the emitters are total: every failure path logs and returns 0).
#
# Acceptance (read-only — no live services, no runner spawned, no push; the
# dispatcher's emit path is exercised in-process against a fixture vault
# action dir, per issue-1398):
#   1. Firing an approved fixture action and observing its result.json
#      appends exactly one proposal line (loop=production, class=formula,
#      context={"target":<host>}, decision=approved, id=ref=<action id>, no
#      parent/caused_by/forecast) and one outcome line (bits
#      {"returned":1,"ok":1}, numbers.duration_s a number >= 0,
#      children={}, payloads=[sha256 of the result file], content-addressed
#      under $PAYLOAD_DIR)
#   2. A failed run appends an outcome with bits.ok=0; a TOML without a
#      host yields context={"target":""}
#   3. An action that never fired (no fire-epoch file — e.g. rejected before
#      launch) gets NO outcome record
#   4. Unwritable TAPE_DIR/PAYLOAD_DIR: the emitters warn and return 0 —
#      dispatch continues; no record and no fire-epoch file are left behind
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq
ac_require_cmd sha256sum

TARGET="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$TARGET" "docker/edge/dispatcher.sh must exist"

# ── 1. wiring: the dispatcher sources the tape lib and calls the emitters ──
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "dispatcher.sh must source lib/tape.sh"
grep -q 'emit_tape_proposal "\$action_id"' "$TARGET" \
  || ac_fail "dispatcher.sh must record the fire of an approved action (emit_tape_proposal)"
grep -q 'emit_tape_outcome "\$action_id"' "$TARGET" \
  || ac_fail "dispatcher.sh must record the observed result.json (emit_tape_outcome)"

PROPOSAL_SRC="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$PROPOSAL_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dispatcher.sh"
OUTCOME_SRC="$(ac_extract_fn emit_tape_outcome "$TARGET")"
[ -n "$OUTCOME_SRC" ] || ac_fail "could not extract emit_tape_outcome() from dispatcher.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1407"   # sentinel — never collides with live fire-epoch files
export PROJECT_NAME
trap 'rm -rf "$TMP_DIR" /tmp/dispatcher-tape-start-acceptance-1407-*' EXIT

# The extracted emitters log via log(); subshells inherit this stand-in.
log() { echo "dispatcher: $*"; }

# ── fixture vault action dir ─────────────────────────────────────────────────
# Two fixture actions shaped like action-vault/examples (one approved
# success, one approved failure). The emitters read VAULT_ACTION_* exactly
# as validate_vault_action exports them; the values below mirror the TOMLs.
FIXTURE_ACTIONS="$TMP_DIR/vault/actions"
mkdir -p "$FIXTURE_ACTIONS"
ACTION_OK="fixture-publish-1407"
cat > "$FIXTURE_ACTIONS/${ACTION_OK}.toml" <<'TOML'
id = "fixture-publish-1407"
formula = "clawhub-publish"
context = "Publish the fixture skill to ClawHub"
secrets = ["CLAWHUB_TOKEN"]
host = "nomad-box-1"
TOML
ACTION_FAIL="fixture-experiment-1407"
cat > "$FIXTURE_ACTIONS/${ACTION_FAIL}.toml" <<'TOML'
id = "fixture-experiment-1407"
formula = "run-experiment"
context = "Run the fixture experiment"
secrets = []
TOML
[ -f "$FIXTURE_ACTIONS/${ACTION_OK}.toml" ] || ac_fail "fixture vault action dir incomplete"

# write_result <action-id> <exit-code> — materialise the result.json the
# dispatcher produces, in the exact JSON shape commit_result_via_git writes
# (id, exit_code, timestamp, logs).
write_result() {
  local action_id="$1" exit_code="$2"
  jq -n --arg id "$action_id" --argjson ec "$exit_code" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg logs "fixture runner logs" \
    '{id: $id, exit_code: $ec, timestamp: $timestamp, logs: $logs}' \
    > "$TMP_DIR/${action_id}.result.json"
  echo "$TMP_DIR/${action_id}.result.json"
}

# run_emit_path <tape-dir> <payload-dir> <formula> <host> <action-id> \
#               <exit-code> [result-file]
# Run the dispatcher's emit path in an isolated subshell: source the real
# lib/tape.sh, define the two extracted emitters, then fire an approved
# action (proposal) and observe its result.json (outcome) — the same call
# sequence launch_runner + commit_result_via_git performs in production.
# Captures combined output; returns the last emitter's exit status.
run_emit_path() {
  local tape_dir="$1" payload_dir="$2" formula="$3" host="$4" action_id="$5" \
        exit_code="$6" result_file="${7:-}"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$payload_dir"
    export VAULT_ACTION_FORMULA="$formula" VAULT_ACTION_HOST="$host"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$PROPOSAL_SRC"
    eval "$OUTCOME_SRC"
    emit_tape_proposal "$action_id"
    emit_tape_outcome "$action_id" "$exit_code" "$result_file"
  ) 2>&1
}

# ── 1. happy path: fire an approved action, observe its result.json ─────────
TAPE1="$TMP_DIR/tape-happy"
PAYLOAD1="$TMP_DIR/payloads-happy"
RESULT_OK="$(write_result "$ACTION_OK" 0)"
rc=0
out="$(run_emit_path "$TAPE1" "$PAYLOAD1" "clawhub-publish" "nomad-box-1" "$ACTION_OK" 0 "$RESULT_OK")" || rc=$?
ac_assert_eq "$rc" "0" "the dispatcher's emit path must return 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "no tape records were appended"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "2" \
  "one fire + one observed result.json must append exactly one proposal and one outcome line"

LINE1="$(head -n 1 "$TAPE1/tape.jsonl")"
ac_assert_jq "$(cat <<JQ
.type == "proposal"
  and .loop == "production"
  and .class == "clawhub-publish"
  and .context == {"target": "nomad-box-1"}
  and .decision == "approved"
  and .id == "$ACTION_OK"
  and .ref == "$ACTION_OK"
  and (.parent | not)
  and (.caused_by | not)
  and (.forecast | not)
JQ
)" "$LINE1" \
  "line 1 must be the approved production proposal keyed by the action id"

LINE2="$(sed -n '2p' "$TAPE1/tape.jsonl")"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$ACTION_OK"
  and .bits == {"returned": 1, "ok": 1}
  and (.numbers.duration_s | type == "number")
  and .numbers.duration_s >= 0
  and .children == {}
  and (.payloads | length == 1)
  and (.payloads[0] | test("^[0-9a-f]{64}$"))
JQ
)" "$LINE2" \
  "line 2 must be the outcome with returned/ok bits, a duration, and one result-file payload"

PAYLOAD_REF="$(jq -r '.payloads[0]' <<<"$LINE2")"
[ -f "$PAYLOAD1/$PAYLOAD_REF" ] \
  || ac_fail "payload $PAYLOAD_REF not content-addressed under $PAYLOAD1"
ac_assert_eq "$(sha256sum "$PAYLOAD1/$PAYLOAD_REF" | cut -d' ' -f1)" \
  "$(sha256sum "$RESULT_OK" | cut -d' ' -f1)" \
  "the stored payload must be byte-identical to the result file"

# ── 2. failed run: ok=0; TOML without a host → context={"target":""} ────────
TAPE2="$TMP_DIR/tape-fail"
PAYLOAD2="$TMP_DIR/payloads-fail"
RESULT_FAIL="$(write_result "$ACTION_FAIL" 1)"
rc=0
out="$(run_emit_path "$TAPE2" "$PAYLOAD2" "run-experiment" "" "$ACTION_FAIL" 1 "$RESULT_FAIL")" || rc=$?
ac_assert_eq "$rc" "0" "the emit path must return 0 for a failed run (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "2" \
  "a failed run still appends one proposal and one outcome line"
ac_assert_jq "$(cat <<JQ
.type == "proposal" and .class == "run-experiment"
  and .context == {"target": ""}
JQ
)" "$(head -n 1 "$TAPE2/tape.jsonl")" \
  "the proposal for a host-less action must carry context={\"target\":\"\"}"
ac_assert_jq "$(cat <<JQ
.type == "outcome" and .proposal_id == "$ACTION_FAIL"
  and .bits == {"returned": 1, "ok": 0}
  and (.payloads | length == 1)
JQ
)" "$(sed -n '2p' "$TAPE2/tape.jsonl")" \
  "the outcome for a failed run must carry ok=0 and the result-file payload"

# ── 3. never fired: no fire-epoch file → the outcome is skipped silently ────
TAPE3="$TMP_DIR/tape-never"
RESULT_NEVER="$(write_result "fixture-rejected-1407" 1)"
rc=0
out="$(
  set -euo pipefail
  export TAPE_DIR="$TAPE3" PAYLOAD_DIR="$TMP_DIR/payloads-never"
  # shellcheck disable=SC1091  # path is known only at runtime
  source "$REPO_ROOT/lib/tape.sh"
  eval "$OUTCOME_SRC"
  emit_tape_outcome "fixture-rejected-1407" 1 "$RESULT_NEVER"
) 2>&1" || rc=$?
ac_assert_eq "$rc" "0" "an observed result for a never-fired action must not fail (got $rc): $out"
[ ! -f "$TAPE3/tape.jsonl" ] \
  || ac_fail "a never-fired action must not get an outcome record"

# ── 4. unwritable TAPE_DIR/PAYLOAD_DIR: warn + continue, dispatch unblocked ─
# A directory can never be created under a plain file — mkdir -p must fail,
# so no record can land.
touch "$TMP_DIR/blocker"
TAPE4="$TMP_DIR/blocker/tape"
PAYLOAD4="$TMP_DIR/blocker/payloads"
ACTION_BLOCKED="fixture-blocked-1407"
RESULT_BLOCKED="$(write_result "$ACTION_BLOCKED" 0)"
rc=0
out="$(run_emit_path "$TAPE4" "$PAYLOAD4" "clawhub-publish" "nomad-box-1" "$ACTION_BLOCKED" 0 "$RESULT_BLOCKED")" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the dispatch (got $rc): $out"
case "$out" in
  *"tape: failed to append"*) ;;
  *) ac_fail "an unwritable TAPE_DIR must log a tape warning, got: $out" ;;
esac
[ ! -f "$TAPE4/tape.jsonl" ] \
  || ac_fail "no tape record may be written when TAPE_DIR is unwritable"
[ ! -f "/tmp/dispatcher-tape-start-${PROJECT_NAME}-${ACTION_BLOCKED}" ] \
  || ac_fail "no fire-epoch file may be left behind when the tape append fails"

ac_pass
