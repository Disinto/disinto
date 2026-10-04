#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1630.sh
#
# Issue #1630: the dispatcher records a fired vault action on the vault
# loop, with the cost of the action on a run under that proposal.
#
#   fire (launch_runner, right after emit_tape_proposal):
#     tape_proposal <action-id> vault "<formula>" ... "approved" <action-id>
#     tape_run <action-id> dispatcher "$DISPATCHER_BACKEND" <started> '' 1 '{}' ''
#     start epoch → ${TAPE_DIR}/vault-runs/<action-id>
#
#   result (commit_result_via_git, before emit_tape_outcome):
#     tape_run ... <ended> 1 '{"duration_s":N}' completed|failed
#     (cost {} when the start file is missing), then delete the start file,
#     then the outcome.
#
# No network. The emitters are extracted with ac_extract_fn and run against
# a temp TAPE_DIR. Tape failures stay non-fatal.
#
#   1. A stubbed fire writes a proposal with loop "vault" and an open run
#      for the action id.
#   2. A stubbed result with exit 0 writes a closing run with status
#      "completed" and cost.duration_s, then the outcome.
#   3. A stubbed result with no start file writes a closing run with cost {}.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$TARGET" "docker/edge/dispatcher.sh must exist"

# ── wiring: fire records the proposal then the open run; result closes first
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "dispatcher.sh must source lib/tape.sh"

proposal_line="$(grep -nF 'emit_tape_proposal "$action_id"' "$TARGET" | head -n 1 | cut -d: -f1)"
open_line="$(grep -nF 'record_vault_open_run "$action_id"' "$TARGET" | head -n 1 | cut -d: -f1)"
[ -n "$proposal_line" ] && [ -n "$open_line" ] \
  || ac_fail "fire path must call emit_tape_proposal and record_vault_open_run"
[ "$open_line" -eq $((proposal_line + 1)) ] \
  || ac_fail "record_vault_open_run must follow emit_tape_proposal immediately in the fire path (proposal line ${proposal_line}, open line ${open_line})"

close_line="$(grep -nF 'record_vault_close_run "$action_id" "$exit_code"' "$TARGET" | head -n 1 | cut -d: -f1)"
outcome_line="$(grep -nF 'emit_tape_outcome "$action_id" "$exit_code"' "$TARGET" | head -n 1 | cut -d: -f1)"
[ -n "$close_line" ] && [ -n "$outcome_line" ] \
  || ac_fail "result path must call record_vault_close_run and emit_tape_outcome"
[ "$outcome_line" -eq $((close_line + 1)) ] \
  || ac_fail "emit_tape_outcome must follow record_vault_close_run immediately (close line ${close_line}, outcome line ${outcome_line})"

# The open-run append is the call the issue names.
grep -qF "tape_run \"\$action_id\" dispatcher \"\$DISPATCHER_BACKEND\" \"\$started\" '' 1 '{}' ''" "$TARGET" \
  || ac_fail "open run must be tape_run \"\$action_id\" dispatcher \"\$DISPATCHER_BACKEND\" <started> '' 1 '{}' ''"

FN_PROP="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$FN_PROP" ] || ac_fail "could not extract emit_tape_proposal() from dispatcher.sh"
FN_OPEN="$(ac_extract_fn record_vault_open_run "$TARGET")"
[ -n "$FN_OPEN" ] || ac_fail "could not extract record_vault_open_run() from dispatcher.sh"
FN_CLOSE="$(ac_extract_fn record_vault_close_run "$TARGET")"
[ -n "$FN_CLOSE" ] || ac_fail "could not extract record_vault_close_run() from dispatcher.sh"
FN_OUT="$(ac_extract_fn emit_tape_outcome "$TARGET")"
[ -n "$FN_OUT" ] || ac_fail "could not extract emit_tape_outcome() from dispatcher.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1630"
export PROJECT_NAME
trap 'rm -rf "$TMP_DIR" /tmp/dispatcher-tape-start-acceptance-1630-*' EXIT

log() { echo "dispatcher: $*"; }

# run_fns <tape-dir> <script>
# Source the real tape lib and the extracted emitters, then run <script>.
run_fns() {
  local tape_dir="$1" script="$2"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$tape_dir/payloads"
    export DISPATCHER_BACKEND="docker"
    export VAULT_ACTION_FORMULA="clawhub-publish" VAULT_ACTION_HOST="nomad-box-1"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/stats.sh"
    eval "$FN_PROP"
    eval "$FN_OPEN"
    eval "$FN_CLOSE"
    eval "$FN_OUT"
    eval "$script"
  ) 2>&1
}

ACTION_ID="fixture-vault-1630"

# ── 1. stubbed fire: vault proposal + open run + start epoch ────────────────
TAPE1="$TMP_DIR/tape-fire"
rc=0
out="$(run_fns "$TAPE1" "
  emit_tape_proposal \"$ACTION_ID\"
  record_vault_open_run \"$ACTION_ID\"
")" || rc=$?
ac_assert_eq "$rc" "0" "stubbed fire must return 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "stubbed fire wrote no tape records"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "2" \
  "stubbed fire must append exactly one proposal and one open run"

ac_assert_jq "$(cat <<JQ
.type == "proposal"
  and .loop == "vault"
  and .class == "clawhub-publish"
  and .id == "$ACTION_ID"
  and .ref == "$ACTION_ID"
  and .decision == "approved"
JQ
)" "$(head -n 1 "$TAPE1/tape.jsonl")" \
  "the fire proposal must be loop vault, keyed by the action id"

ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_ID"
  and .organ == "dispatcher"
  and .agent == "docker"
  and .attempts == 1
  and .cost == {}
  and .ended == null
  and .status == null
  and (.started | type == "string" and length > 0)
JQ
)" "$(sed -n '2p' "$TAPE1/tape.jsonl")" \
  "the fire must append an open run for the action id"

ac_assert_file "$TAPE1/vault-runs/$ACTION_ID" "fire must write the start epoch"
case "$(cat "$TAPE1/vault-runs/$ACTION_ID")" in
  ''|*[!0-9]*) ac_fail "start file must hold an epoch, got: $(cat "$TAPE1/vault-runs/$ACTION_ID")" ;;
esac
ac_log "AC 1: stubbed fire writes a vault proposal and an open run"

# ── 2. stubbed result exit 0: closing run, then the outcome ─────────────────
RESULT2="$TMP_DIR/result-ok.json"
printf '%s\n' '{"id":"fixture-vault-1630","exit_code":0}' > "$RESULT2"
rc=0
out="$(run_fns "$TAPE1" "
  record_vault_close_run \"$ACTION_ID\" 0
  emit_tape_outcome \"$ACTION_ID\" 0 \"$RESULT2\"
")" || rc=$?
ac_assert_eq "$rc" "0" "stubbed result must return 0 (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "4" \
  "result must append a closing run and then an outcome"

ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_ID"
  and .organ == "dispatcher"
  and .agent == "docker"
  and .status == "completed"
  and .attempts == 1
  and (.cost.duration_s | type == "number")
  and .cost.duration_s >= 0
  and (.ended | type == "string" and length > 0)
JQ
)" "$(sed -n '3p' "$TAPE1/tape.jsonl")" \
  "line 3 must be the completed closing run with cost.duration_s"

ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$ACTION_ID"
  and .bits == {"returned": 1, "ok": 1}
JQ
)" "$(sed -n '4p' "$TAPE1/tape.jsonl")" \
  "the outcome must follow the closing run"

[ ! -e "$TAPE1/vault-runs/$ACTION_ID" ] \
  || ac_fail "the start file must be deleted after the closing run"
ac_log "AC 2: exit 0 closes the run completed with duration_s, then the outcome"

# ── 3. stubbed result, no start file: closing run cost {} ───────────────────
TAPE3="$TMP_DIR/tape-nostart"
ACTION_NONE="fixture-nostart-1630"
rc=0
out="$(run_fns "$TAPE3" "
  record_vault_close_run \"$ACTION_NONE\" 0
")" || rc=$?
ac_assert_eq "$rc" "0" "a result with no start file must return 0 (got $rc): $out"
ac_assert_file "$TAPE3/tape.jsonl" "a result with no start file must still append a closing run"
ac_assert_eq "$(wc -l < "$TAPE3/tape.jsonl")" "1" \
  "no start file must append exactly one closing run"
ac_assert_jq "$(cat <<JQ
.type == "run"
  and .proposal_id == "$ACTION_NONE"
  and .status == "completed"
  and .cost == {}
JQ
)" "$(head -n 1 "$TAPE3/tape.jsonl")" \
  "a missing start file must close the run with cost {}"
ac_log "AC 3: no start file closes the run with cost {}"

# ── tape failure stays non-fatal ────────────────────────────────────────────
touch "$TMP_DIR/blocker"
rc=0
out="$(run_fns "$TMP_DIR/blocker/tape" "
  emit_tape_proposal \"$ACTION_ID\"
  record_vault_open_run \"$ACTION_ID\"
")" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the fire (got $rc): $out"
case "$out" in
  *"tape: failed"*) ;;
  *) ac_fail "an unwritable TAPE_DIR must log a tape warning, got: $out" ;;
esac
ac_log "tape failure is non-fatal"

ac_pass
