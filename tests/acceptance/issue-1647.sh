#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1647.sh
#
# Issue #1647: an attempt that pushed nothing gets a signed outcome.
#
# When an attempt ends without a push, no_push_outcome re-queues or blocks the
# issue, but the terminal outcome close_dev_tape_outcome writes carried
# {merged:0, ci_green:0} and no signature, because _PR_WALK_EXIT_REASON was
# empty on this path. Calibration could not tell a timeout from a harness death.
#
# Fix: no_push_outcome sets _PR_WALK_EXIT_REASON to the reason it acts on,
# before issue_block / issue_requeue:
#   re-queue: the requeue_reason (timeout, error_max_turns, or no_result);
#   block:    no_push_after_3_attempts or no_push.
# The function runs in the main shell, so the EXIT trap's
# close_dev_tape_outcome sees the value and maps it through rubrics/dev.toml
# the same way as any failed walk.
#
# Acceptance (self-contained — both functions are extracted with ac_extract_fn;
# issue_block and issue_requeue are stubbed; tape and rubric live under
# $TMP_DIR; no network, no agent):
#   1. rc 124, attempt 0: after the call _PR_WALK_EXIT_REASON is timeout
#   2. rc 124, attempt 2: it is no_push_after_3_attempts
#   3. a fixture rubric mapping timeout = "agent-loop", then
#      close_dev_tape_outcome writes signature: "agent-loop"
#
# Run via: tools/run-acceptance.sh 1647
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-no-push-harness.sh"

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

ac_require_cmd bash jq awk python3 flock

ISSUE=1647
BRANCH="fix/issue-${ISSUE}"
# shellcheck disable=SC2034 # consumed by the sourced no-push harness / extracted fn
NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"
# Sentinel — can never clobber a live proposal id file.
PROJECT_NAME="acceptance-1647"

# The harness owns $TMP_DIR. Extend its EXIT trap to also drop the id file
# close_dev_tape_outcome reads from /tmp.
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-${ISSUE}"
# shellcheck disable=SC2153  # TMP_DIR is assigned by acceptance-no-push-harness.sh
trap 'rm -rf "$TMP_DIR"; rm -f "$ID_FILE"' EXIT

# Hermetic rubric: only the reason this issue's timeout path acts on.
# The fixture lives under $TMP_DIR so no signature name is committed.
RUBRICS_DIR="$TMP_DIR/rubrics"
mkdir -p "$RUBRICS_DIR"
cat > "$RUBRICS_DIR/dev.toml" <<'EOF'
[map]
timeout = "agent-loop"
EOF
export RUBRICS_DIR

TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"
export TAPE_DIR

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/tape.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/signature.sh"

# Silence the extracted outcome writer. The harness does not define log().
# shellcheck disable=SC2317
log() { :; }

ac_no_push_stub
ac_load_decision_fn "$TARGET" "no_push_outcome"
ac_load_decision_fn "$TARGET" "close_dev_tape_outcome"

DIAG="$TMP_DIR/timeout.json"
printf '%s\n' \
  '{"type":"result","subtype":"no_result","session_id":"s-t","num_turns":1}' \
  > "$DIAG"

# ── 1. rc 124, attempt 0 -> _PR_WALK_EXIT_REASON=timeout ─────────────────────
ac_log "AC 1: rc 124, attempt 0 -> _PR_WALK_EXIT_REASON=timeout"
_PR_WALK_EXIT_REASON=""
no_push_outcome "$ISSUE" "$DIAG" 124 0 "$NO_PUSH_TEXT"
ac_assert_eq "${_PR_WALK_EXIT_REASON:-}" "timeout" \
  "rc 124 attempt 0 must set _PR_WALK_EXIT_REASON=timeout (got: '${_PR_WALK_EXIT_REASON:-}')"
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "rc 124 attempt 0 must still re-queue as timeout, got: ${CALLS[*]:-nothing}"
ac_log "AC 1 OK"

# ── 2. rc 124, attempt 2 -> no_push_after_3_attempts ─────────────────────────
ac_log "AC 2: rc 124, attempt 2 -> _PR_WALK_EXIT_REASON=no_push_after_3_attempts"
CALLS=()
_PR_WALK_EXIT_REASON=""
no_push_outcome "$ISSUE" "$DIAG" 124 2 "$NO_PUSH_TEXT"
ac_assert_eq "${_PR_WALK_EXIT_REASON:-}" "no_push_after_3_attempts" \
  "rc 124 attempt 2 must set _PR_WALK_EXIT_REASON=no_push_after_3_attempts (got: '${_PR_WALK_EXIT_REASON:-}')"
ac_has_call_matching "issue_block ${ISSUE} no_push_after_3_attempts " \
  || ac_fail "rc 124 attempt 2 must still block no_push_after_3_attempts, got: ${CALLS[*]:-nothing}"
ac_log "AC 2 OK"

# ── 3. fixture rubric timeout=agent-loop -> signed outcome ───────────────────
# Re-run the re-queue arm so the reason close_dev_tape_outcome reads is the
# one no_push_outcome just set (timeout), not a value the test planted.
ac_log "AC 3: close_dev_tape_outcome signs timeout as agent-loop"
CALLS=()
_PR_WALK_EXIT_REASON=""
no_push_outcome "$ISSUE" "$DIAG" 124 0 "$NO_PUSH_TEXT"
ac_assert_eq "${_PR_WALK_EXIT_REASON:-}" "timeout" \
  "precondition: no_push_outcome left _PR_WALK_EXIT_REASON=timeout"

printf '%s\n' "acceptance-proposal-1647" > "$ID_FILE"
# Failure-walk shape: no recorded refusal, walk did not merge. The reason
# must come from no_push_outcome, not from this setup.
# shellcheck disable=SC2034 # consumed by the extracted close_dev_tape_outcome
PR_WALK_RC=1
_DEV_REFUSAL_STATUS=""
_DEV_TAPE_OUTCOME_WRITTEN=0

rc=0
close_dev_tape_outcome || rc=$?
ac_assert_eq "$rc" "0" "close_dev_tape_outcome must return 0 (got $rc)"
ac_assert_file "$TAPE_DIR/tape.jsonl" "outcome must be appended to the temp tape"

last="$(tail -n 1 "$TAPE_DIR/tape.jsonl")"
printf '%s\n' "$last" | jq -e \
  --arg pid "acceptance-proposal-1647" \
  '.type == "outcome" and .proposal_id == $pid
   and .bits.merged == 0 and .bits.ci_green == 0
   and (.bits.rejected // 0) == 0
   and .signature == "agent-loop"' >/dev/null \
  || ac_fail "timeout no-push must write signature agent-loop, got: $last"
ac_log "AC 3 OK"

ac_pass
