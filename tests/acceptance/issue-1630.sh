#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1630.sh
#
# Issue #1630: the edge dispatcher records the vault loop with a run.
#
# The dispatcher is the vault organ of the proposal loop (lib/tape.sh, #1389).
# #1630 adds run records that bracket each action's cost on its proposal:
#
#   fire (launch_runner, immediately after emit_tape_proposal):
#     tape_run <action-id> dispatcher <backend> <epoch> '' 1 '{}' ''
#       (an OPEN run: started set, attempts 1, cost {}, no ended/status)
#   + the fire epoch is kept at ${TAPE_DIR}/vault-runs/<action-id>.
#
#   result observed (commit_result_via_git, right after the result JSON is
#   written, before the outcome):
#     tape_run <action-id> dispatcher <backend> <started> <now> 1 <cost> <status>
#       (a CLOSING run: status=completed|failed, ended set,
#        cost={"duration_s":<now-started>} when the fire epoch is present,
#        {} when it is not)
#   + the fire-epoch file is removed.
#
# The action's cost belongs on a run under its proposal: a fire opens the run,
# the observed result closes it. A tape failure must warn and continue —
# dispatch is never blocked (the emitters are total: every failure path logs
# a WARNING and returns 0).
#
# Acceptance (read-only — no live services, no runner spawned, no push; the
# dispatcher's emit path is exercised in-process against a fixture vault
# action dir, per issue-1398 / issue-1407):
#   1. A stubbed fire writes a proposal with loop="vault" AND an open run for
#      the action id (organ=dispatcher, agent=<backend>, started set, attempts
#      1, cost {}, no ended/status), and leaves the fire-epoch file at
#      ${TAPE_DIR}/vault-runs/<action-id>.
#   2. A stubbed result with exit 0 appends a closing run (status=completed,
#      ended set, cost.duration_s a number >= 0) THEN the outcome, and removes
#      the fire-epoch file.
#      (a) exit 1 → closing run status=failed, outcome ok=0.
#   3. A stubbed result with no fire-epoch file (never fired) appends a
#      closing run with cost={}.
#   4. Unwritable TAPE_DIR: the open-run + close warn and return 0 — dispatch
#      continues; no tape record and no fire-epoch file are left behind.
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

# ── 1. wiring: the dispatcher sources the tape lib and emits a run ──────────
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "dispatcher.sh must source lib/tape.sh"
grep -q 'emit_tape_proposal "\$action_id"' "$TARGET" \
  || ac_fail "dispatcher.sh must record the fire of an approved action (emit_tape_proposal)"
grep -q 'emit_tape_run_close "\$action_id"' "$TARGET" \
  || ac_fail "dispatcher.sh must close the run on the observed result.json (emit_tape_run_close)"
grep -q 'emit_tape_outcome "\$action_id"' "$TARGET" \
  || ac_fail "dispatcher.sh must record the observed result.json (emit_tape_outcome)"
grep -q 'vault-runs' "$TARGET" \
  || ac_fail "dispatcher.sh must keep the fire epoch under TAPE_DIR/vault-runs"

LAUNCH_SRC="$(ac_extract_fn launch_runner "$TARGET")"
[ -n "$LAUNCH_SRC" ] || ac_fail "could not extract launch_runner() from dispatcher.sh"
PROPOSAL_SRC="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$PROPOSAL_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dispatcher.sh"
CLOSE_SRC="$(ac_extract_fn emit_tape_run_close "$TARGET")"
[ -n "$CLOSE_SRC" ] || ac_fail "could not extract emit_tape_run_close() from dispatcher.sh"
OUTCOME_SRC="$(ac_extract_fn emit_tape_outcome "$TARGET")"
[ -n "$OUTCOME_SRC" ] || ac_fail "could not extract emit_tape_outcome() from dispatcher.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1630"   # sentinel — never collides with live fire-epoch files
export PROJECT_NAME
trap 'rm -rf "$TMP_DIR" /tmp/dispatcher-tape-start-acceptance-1630-*' EXIT

# The extracted functions log via log(); subshells inherit this stand-in.
log() { echo "dispatcher: $*"; }

# ── fixture vault action dir ─────────────────────────────────────────────────
# Two fixture actions shaped like action-vault/examples (one approved success,
# one approved failure). The emitters read VAULT_ACTION_* exactly as
# validate_vault_action exports them; the values below mirror the TOMLs.
FIXTURE_ACTIONS="$TMP_DIR/vault/actions"
mkdir -p "$FIXTURE_ACTIONS"
ACTION_OK="fixture-vault-1630"
cat > "$FIXTURE_ACTIONS/${ACTION_OK}.toml" <<'TOML'
id = "fixture-vault-1630"
formula = "clawhub-publish"
context = "Publish the fixture skill to ClawHub"
secrets = ["CLAWHUB_TOKEN"]
host = "nomad-box-1"
TOML
ACTION_FAIL="fixture-vault-1630-fail"
cat > "$FIXTURE_ACTIONS/${ACTION_FAIL}.toml" <<'TOML'
id = "fixture-vault-1630-fail"
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

# run_fire_path <tape-dir> <payload-dir> <formula> <host> <toml-path> [backend]
# Run the dispatcher's fire path in an isolated subshell: source the real
# lib/tape.sh, define launch_runner + emit_tape_proposal, stub the non-tape
# dependencies, then fire the approved action — exactly launch_runner does at
# fire (proposal, then the open run + fire epoch). Returns the last command's
# exit status (the stubbed runner).
run_fire_path() {
  local tape_dir="$1" payload_dir="$2" formula="$3" host="$4" toml="$5" \
        backend="${6:-docker}"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$payload_dir"
    export VAULT_ACTION_FORMULA="$formula" VAULT_ACTION_HOST="$host"
    export DISPATCHER_BACKEND="$backend"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    # Non-tape dependencies of launch_runner, stubbed to return 0 / direct:
    validate_action() { return 0; }
    get_dispatch_mode() { echo "direct"; }
    verify_admin_merged() { return 0; }
    write_result() { return 0; }
    _launch_runner_docker() { return 0; }
    eval "$LAUNCH_SRC"
    eval "$PROPOSAL_SRC"
    launch_runner "$toml"
  ) 2>&1
}

# run_close_path <tape-dir> <payload-dir> <action-id> <exit-code> [result-file]
# Run the dispatcher's close path in an isolated subshell: source the real
# lib/tape.sh, define emit_tape_run_close + emit_tape_outcome, then observe
# the result — exactly commit_result_via_git does (closing run, then outcome).
# Returns the last command's exit status (0; the emitters are total).
run_close_path() {
  local tape_dir="$1" payload_dir="$2" action_id="$3" exit_code="$4" \
        result_file="${5:-}"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$payload_dir"
    export DISPATCHER_BACKEND="${DISPATCHER_BACKEND:-docker}"
    # shellcheck disable=SC1091  # path is known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$CLOSE_SRC"
    eval "$OUTCOME_SRC"
    emit_tape_run_close "$action_id" "$exit_code"
    emit_tape_outcome "$action_id" "$exit_code" "$result_file"
  ) 2>&1
}

# ── 1. happy fire: proposal + open run, fire epoch left on disk ─────────────
TAPE="$TMP_DIR/tape-happy"
PAYLOAD="$TMP_DIR/payloads-happy"
RESULT_OK="$(write_result "$ACTION_OK" 0)"
rc=0
out="$(run_fire_path "$TAPE" "$PAYLOAD" "clawhub-publish" "nomad-box-1" \
         "$FIXTURE_ACTIONS/${ACTION_OK}.toml")" || rc=$?
ac_assert_eq "$rc" "0" "a stubbed fire must not fail the dispatch (got $rc): $out"
ac_assert_file "$TAPE/tape.jsonl" "no tape records were appended by the fire"
ac_assert_eq "$(wc -l < "$TAPE/tape.jsonl")" "2" \
  "a fire must append exactly one proposal and one open run"

LINE1="$(sed -n '1p' "$TAPE/tape.jsonl")"
ac_assert_jq "$(cat <<JQ
.type == "proposal"
  and .loop == "vault"
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
  "line 1 must be the approved vault proposal keyed by the action id"

LINE2="$(sed -n '2p' "$TAPE/tape.jsonl")"
ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_OK"
  and .organ == "dispatcher"
  and .agent == "docker"
  and (.started | type == "string")
  and .attempts == 1
  and .cost == {}
  and (.ended | not)
  and (.status | not)
JQ
)" "$LINE2" \
  "line 2 must be the open run (started set, no ended/status, cost {})"

[ -f "$TAPE/vault-runs/${ACTION_OK}" ] \
  || ac_fail "the fire epoch file must exist at ${TAPE}/vault-runs/${ACTION_OK}"

# ── 2. observed success: closing run (completed) then the outcome ───────────
RESULT_OK="$(write_result "$ACTION_OK" 0)"
rc=0
out="$(run_close_path "$TAPE" "$PAYLOAD" "$ACTION_OK" 0 "$RESULT_OK")" || rc=$?
ac_assert_eq "$rc" "0" "the close+outcome path must return 0 (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE/tape.jsonl")" "4" \
  "closing a fired action adds exactly one closing run and one outcome"

LINE3="$(sed -n '3p' "$TAPE/tape.jsonl")"
ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_OK"
  and .organ == "dispatcher"
  and .agent == "docker"
  and (.ended | type == "string")
  and .status == "completed"
  and (.cost.duration_s | type == "number")
  and .cost.duration_s >= 0
  and .attempts == 1
JQ
)" "$LINE3" \
  "line 3 must be the closing run (status=completed, ended set, duration_s >= 0)"

LINE4="$(sed -n '4p' "$TAPE/tape.jsonl")"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$ACTION_OK"
  and .bits == {"returned": 1, "ok": 1}
  and (.numbers.duration_s | type == "number")
  and .children == {}
  and (.payloads | length == 1)
  and (.payloads[0] | test("^[0-9a-f]{64}$"))
JQ
)" "$LINE4" \
  "line 4 must be the outcome (ok=1, one result-file payload)"

PAYLOAD_REF="$(jq -r '.payloads[0]' <<<"$LINE4")"
[ -f "$PAYLOAD/${PAYLOAD_REF}" ] \
  || ac_fail "payload $PAYLOAD_REF not content-addressed under $PAYLOAD"
ac_assert_eq "$(sha256sum "$PAYLOAD/${PAYLOAD_REF}" | cut -d' ' -f1)" \
  "$(sha256sum "$RESULT_OK" | cut -d' ' -f1)" \
  "the stored payload must be byte-identical to the result file"

# The fire-epoch file must be gone after the close.
[ ! -f "$TAPE/vault-runs/${ACTION_OK}" ] \
  || ac_fail "the fire-epoch file must be removed after the closing run"

# ── 2a. observed failure: closing run (failed), outcome ok=0 ────────────────
TAPE_FAIL="$TMP_DIR/tape-fail"
PAYLOAD_FAIL="$TMP_DIR/payloads-fail"
RESULT_FAIL="$(write_result "$ACTION_FAIL" 1)"
rc=0
out="$(run_fire_path "$TAPE_FAIL" "$PAYLOAD_FAIL" "run-experiment" "" \
         "$FIXTURE_ACTIONS/${ACTION_FAIL}.toml")" || rc=$?
ac_assert_eq "$rc" "0" "a failed stubbed fire must not fail the dispatch (got $rc): $out"
rc=0
out="$(run_close_path "$TAPE_FAIL" "$PAYLOAD_FAIL" "$ACTION_FAIL" 1 "$RESULT_FAIL")" || rc=$?
ac_assert_eq "$rc" "0" "a failed close+outcome must return 0 (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE_FAIL/tape.jsonl")" "4" \
  "a failed action still appends proposal + open run + closing run + outcome"
ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_FAIL"
  and .status == "failed"
  and (.ended | type == "string")
JQ
)" "$(sed -n '3p' "$TAPE_FAIL/tape.jsonl")" \
  "a failed action's closing run must carry status=failed"
ac_assert_jq "$(cat <<JQ
.type == "outcome" and .proposal_id == "$ACTION_FAIL"
  and .bits == {"returned": 1, "ok": 0}
  and (.payloads | length == 1)
JQ
)" "$(sed -n '4p' "$TAPE_FAIL/tape.jsonl")" \
  "a failed action's outcome must carry ok=0"

# ── 3. never fired (no fire-epoch file): closing run carries cost {} ────────
TAPE_NOFIRE="$TMP_DIR/tape-nofire"
PAYLOAD_NOFIRE="$TMP_DIR/payloads-nofire"
ACTION_NEVER="fixture-rejected-1630"
RESULT_NEVER="$(write_result "$ACTION_NEVER" 0)"
rc=0
out="$(run_close_path "$TAPE_NOFIRE" "$PAYLOAD_NOFIRE" "$ACTION_NEVER" 0 "$RESULT_NEVER")" || rc=$?
ac_assert_eq "$rc" "0" "a close for a never-fired action must not fail (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE_NOFIRE/tape.jsonl")" "1" \
  "a never-fired action appends only the closing run (no proposal, no outcome)"
ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_NEVER"
  and .organ == "dispatcher"
  and .agent == "docker"
  and .status == "completed"
  and (.ended | type == "string")
  and (.started | type == "string")
  and .cost == {}
  and .attempts == 1
JQ
)" "$(sed -n '1p' "$TAPE_NOFIRE/tape.jsonl")" \
  "a closing run without a fire epoch must carry cost={}"

# ── 4. unwritable TAPE_DIR/PAYLOAD_DIR: warn + continue, dispatch unblocked ─
# A directory can never be created under a plain file — mkdir -p must fail,
# so no record and no fire epoch can land.
touch "$TMP_DIR/blocker"
TAPE4="$TMP_DIR/blocker/tape"
PAYLOAD4="$TMP_DIR/blocker/payloads"
ACTION_BLOCKED="fixture-blocked-1630"
RESULT_BLOCKED="$(write_result "$ACTION_BLOCKED" 0)"
rc_fire=0
out_fire="$(run_fire_path "$TAPE4" "$PAYLOAD4" "clawhub-publish" "nomad-box-1" \
              "$FIXTURE_ACTIONS/${ACTION_BLOCKED}.toml")" || rc_fire=$?
rc_close=0
out_close="$(run_close_path "$TAPE4" "$PAYLOAD4" "$ACTION_BLOCKED" 0 "$RESULT_BLOCKED")" || rc_close=$?
ac_assert_eq "$rc_fire" "0" "an unwritable TAPE_DIR must not fail the fire (got $rc_fire): $out_fire"
ac_assert_eq "$rc_close" "0" "an unwritable TAPE_DIR must not fail the close (got $rc_close): $out_close"
case "$out_fire
$out_close" in
  *"tape: failed to append"*) ;;
  *) ac_fail "an unwritable TAPE_DIR must log a tape warning, got: $out_fire\n$out_close" ;;
esac
[ ! -f "$TAPE4/tape.jsonl" ] \
  || ac_fail "no tape record may be written when TAPE_DIR is unwritable"
[ ! -f "$TAPE4/vault-runs/${ACTION_BLOCKED}" ] \
  || ac_fail "no fire-epoch file may be left behind when TAPE_DIR is unwritable"
[ ! -f "/tmp/dispatcher-tape-start-${PROJECT_NAME}-${ACTION_BLOCKED}" ] \
  || ac_fail "no /tmp fire-epoch file may be left behind when the tape append fails"

ac_pass
