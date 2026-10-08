#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1986.sh
#
# Issue #1986: a wall-clock timeout on the local model hands the issue to the
# Grok dev agent instead of blocking after three timeouts.
#
# no_push_outcome re-queues a resource-limit exit twice and blocks on the
# third (no_push_after_3_attempts). With DEV_ESCALATE_TO set to another login,
# rc 124 escalates on the first timeout: issue_requeue reason timeout, then
# PATCH assignees to ["${DEV_ESCALATE_TO}"]. issue_block is not called.
# Unset, or set to this agent's own login, keeps today's behaviour.
# error_max_turns (no rc 124) is unchanged.
#
# Acceptance (self-contained — no_push_outcome is extracted; issue_requeue,
# issue_block, forge_whoami and curl are stubbed; no network, no model):
#   1. DEV_ESCALATE_TO=dev-grok-bot, login dev-bot, rc 124, attempt 0:
#      issue_requeue timeout, PATCH assignees ["dev-grok-bot"], no issue_block
#   2. the same at attempt 2: escalated, not blocked
#   3. DEV_ESCALATE_TO unset, rc 124: re-queue at attempts 0–1, block at 2
#   4. DEV_ESCALATE_TO=dev-grok-bot, login dev-grok-bot: today's behaviour
#   5. subtype error_max_turns without rc 124: today's behaviour
#   6. agents-dev-qwen.hcl sets DEV_ESCALATE_TO = "dev-grok-bot"
#      (nomad job validate of nomad/jobs/*.hcl is the CI step; this test
#      needs no nomad binary)
#
# Run via: tools/run-acceptance.sh 1986
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
JOBSPEC="$REPO_ROOT/nomad/jobs/agents-dev-qwen.hcl"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"
ac_assert_file "$JOBSPEC" "nomad/jobs/agents-dev-qwen.hcl must exist"

ac_require_cmd bash jq

ISSUE=1986
BRANCH="fix/issue-${ISSUE}"
# shellcheck disable=SC2034 # consumed by the extracted no_push_outcome
NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"
FORGE_API="http://forge.example/api/v1/repos/disinto-admin/disinto"
FORGE_TOKEN="test-token"
export FORGE_API FORGE_TOKEN

# The harness owns $TMP_DIR. Stubs record into the calling shell.
DIAG="$TMP_DIR/diag.json"
printf '%s\n' '{"type":"result","subtype":"success","session_id":"s","num_turns":1}' > "$DIAG"
DIAG_MAX_TURNS="$TMP_DIR/max-turns.json"
printf '%s\n' '{"type":"result","subtype":"error_max_turns","session_id":"s","num_turns":100}' > "$DIAG_MAX_TURNS"

CURL_ARGS=()
LOGS=()
FAKE_LOGIN="dev-bot"
# CURL_RC / CURL_CODE let a case force a failed PATCH without replacing curl.
CURL_RC=0
CURL_CODE="201"
# curl runs inside $(...), so an array append in the stub is lost. A file
# survives the subshell.
CURL_LOG="$TMP_DIR/curl-calls.txt"
: > "$CURL_LOG"

# shellcheck disable=SC2317 # called by the extracted function
issue_block() { CALLS+=("issue_block $*"); }
# shellcheck disable=SC2317
issue_requeue() { CALLS+=("issue_requeue $*"); }
# shellcheck disable=SC2317
forge_api() { :; }
# shellcheck disable=SC2317
forge_whoami() { printf '%s\n' "$FAKE_LOGIN"; }
# shellcheck disable=SC2317
log() { LOGS+=("$*"); }
# shellcheck disable=SC2317
curl() {
  printf '%s\n' "$*" >> "$CURL_LOG"
  if [ "$CURL_RC" -ne 0 ]; then
    return "$CURL_RC"
  fi
  printf '%s' "$CURL_CODE"
}

ac_load_decision_fn "$TARGET" "no_push_outcome"

run_outcome() {
  local rc="$1" attempt="$2" diag="${3:-$DIAG}"
  CALLS=()
  LOGS=()
  : > "$CURL_LOG"
  DEV_CARRY=9
  _PR_WALK_EXIT_REASON=""
  local fn_rc=0
  no_push_outcome "$ISSUE" "$diag" "$rc" "$attempt" "$NO_PUSH_TEXT" || fn_rc=$?
  ac_assert_eq "$fn_rc" "0" "no_push_outcome must return 0 (got $fn_rc)"
  CURL_ARGS=()
  if [ -s "$CURL_LOG" ]; then
    mapfile -t CURL_ARGS < "$CURL_LOG"
  fi
}

assert_no_patch() {
  [ "${#CURL_ARGS[@]}" -eq 0 ] \
    || ac_fail "must not PATCH assignees, got: ${CURL_ARGS[*]:-}"
}

assert_escalated() {
  local what="$1"
  ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
    || ac_fail "${what}: expected issue_requeue ${ISSUE} timeout, got: ${CALLS[*]:-nothing}"
  ac_has_call_matching "Resource limit (timeout) — escalated to ${DEV_ESCALATE_TO}" \
    || ac_fail "${what}: requeue message must name the escalation target, got: ${CALLS[*]:-nothing}"
  if ac_has_call_matching "issue_block "; then
    ac_fail "${what}: must NOT call issue_block, got: ${CALLS[*]}"
  fi
  ac_assert_eq "${DEV_CARRY:-}" "0" "${what}: DEV_CARRY must be 0 (got '${DEV_CARRY:-}')"
  ac_assert_eq "${_PR_WALK_EXIT_REASON:-}" "timeout" \
    "${what}: _PR_WALK_EXIT_REASON must be timeout (got '${_PR_WALK_EXIT_REASON:-}')"
  [ "${#CURL_ARGS[@]}" -eq 1 ] \
    || ac_fail "${what}: expected one PATCH, got ${#CURL_ARGS[@]}: ${CURL_ARGS[*]:-nothing}"
  case "${CURL_ARGS[0]}" in
    *"-X PATCH"*) ;;
    *) ac_fail "${what}: curl must PATCH, got: ${CURL_ARGS[0]}" ;;
  esac
  case "${CURL_ARGS[0]}" in
    *"${FORGE_API}/issues/${ISSUE}"*) ;;
    *) ac_fail "${what}: PATCH must target ${FORGE_API}/issues/${ISSUE}, got: ${CURL_ARGS[0]}" ;;
  esac
  case "${CURL_ARGS[0]}" in
    *'{"assignees":["dev-grok-bot"]}'*) ;;
    *) ac_fail "${what}: PATCH must set assignees to [\"dev-grok-bot\"], got: ${CURL_ARGS[0]}" ;;
  esac
  [ "${#LOGS[@]}" -eq 0 ] \
    || ac_fail "${what}: a successful PATCH must not log a WARNING, got: ${LOGS[*]}"
}

# ── 1. escalate on the first timeout ─────────────────────────────────────────
ac_log "AC 1: DEV_ESCALATE_TO=dev-grok-bot, login dev-bot, rc 124, attempt 0"
unset DEV_ESCALATE_TO
DEV_ESCALATE_TO="dev-grok-bot"
export DEV_ESCALATE_TO
FAKE_LOGIN="dev-bot"
CURL_RC=0
CURL_CODE="201"
run_outcome 124 0
assert_escalated "attempt 0"
ac_log "AC 1 OK"

# ── 2. escalate at the attempt that would otherwise block ────────────────────
ac_log "AC 2: same escalation at attempt 2, not blocked"
run_outcome 124 2
assert_escalated "attempt 2"
if ac_has_call_matching "no_push_after_3_attempts"; then
  ac_fail "attempt 2 must escalate, not block no_push_after_3_attempts"
fi
ac_log "AC 2 OK"

# ── 3. unset: today's re-queue-then-block ────────────────────────────────────
ac_log "AC 3: DEV_ESCALATE_TO unset, rc 124 keeps today's behaviour"
unset DEV_ESCALATE_TO
FAKE_LOGIN="dev-bot"
run_outcome 124 0
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "unset attempt 0 must re-queue timeout, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_block "; then
  ac_fail "unset attempt 0 must not block"
fi
if ac_has_call_matching "escalated to"; then
  ac_fail "unset attempt 0 must not escalate"
fi
ac_assert_eq "${DEV_CARRY:-}" "1" "unset attempt 0 must carry (DEV_CARRY=1)"
assert_no_patch
run_outcome 124 1
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "unset attempt 1 must re-queue timeout, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_block "; then
  ac_fail "unset attempt 1 must not block"
fi
assert_no_patch
run_outcome 124 2
ac_has_call_matching "issue_block ${ISSUE} no_push_after_3_attempts " \
  || ac_fail "unset attempt 2 must block no_push_after_3_attempts, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_requeue "; then
  ac_fail "unset attempt 2 must not re-queue"
fi
ac_assert_eq "${_PR_WALK_EXIT_REASON:-}" "no_push_after_3_attempts" \
  "unset attempt 2 must record no_push_after_3_attempts"
assert_no_patch
ac_log "AC 3 OK"

# ── 4. never escalate to itself ──────────────────────────────────────────────
ac_log "AC 4: DEV_ESCALATE_TO equals this login — today's behaviour"
DEV_ESCALATE_TO="dev-grok-bot"
export DEV_ESCALATE_TO
FAKE_LOGIN="dev-grok-bot"
run_outcome 124 0
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "self login attempt 0 must re-queue timeout, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "escalated to"; then
  ac_fail "must not escalate to itself"
fi
ac_assert_eq "${DEV_CARRY:-}" "1" "self login attempt 0 must carry"
assert_no_patch
run_outcome 124 2
ac_has_call_matching "issue_block ${ISSUE} no_push_after_3_attempts " \
  || ac_fail "self login attempt 2 must block, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_requeue "; then
  ac_fail "self login attempt 2 must not re-queue"
fi
assert_no_patch
ac_log "AC 4 OK"

# ── 5. error_max_turns without rc 124 is unchanged ───────────────────────────
ac_log "AC 5: error_max_turns without rc 124 keeps today's behaviour"
FAKE_LOGIN="dev-bot"
DEV_ESCALATE_TO="dev-grok-bot"
export DEV_ESCALATE_TO
run_outcome 0 0 "$DIAG_MAX_TURNS"
ac_has_call_matching "issue_requeue ${ISSUE} error_max_turns " \
  || ac_fail "error_max_turns attempt 0 must re-queue, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_requeue ${ISSUE} timeout "; then
  ac_fail "error_max_turns must not be reported as timeout"
fi
if ac_has_call_matching "escalated to"; then
  ac_fail "error_max_turns must not escalate"
fi
assert_no_patch
run_outcome 0 1 "$DIAG_MAX_TURNS"
ac_has_call_matching "issue_requeue ${ISSUE} error_max_turns " \
  || ac_fail "error_max_turns attempt 1 must re-queue, got: ${CALLS[*]:-nothing}"
assert_no_patch
run_outcome 0 2 "$DIAG_MAX_TURNS"
ac_has_call_matching "issue_block ${ISSUE} no_push_after_3_attempts " \
  || ac_fail "error_max_turns attempt 2 must block, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_requeue "; then
  ac_fail "error_max_turns attempt 2 must not re-queue"
fi
assert_no_patch
ac_log "AC 5 OK"

# A failed PATCH still leaves the issue re-queued and does not abort.
ac_log "AC 5b: a failed PATCH logs a WARNING and still re-queues"
FAKE_LOGIN="dev-bot"
CURL_RC=22
CURL_CODE="201"
run_outcome 124 0
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "failed PATCH must still re-queue, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_block "; then
  ac_fail "failed PATCH must not block"
fi
[ "${#LOGS[@]}" -ge 1 ] || ac_fail "failed PATCH must log a WARNING"
case "${LOGS[0]}" in
  WARNING:*) ;;
  *) ac_fail "PATCH failure log must be a WARNING, got: ${LOGS[0]}" ;;
esac
CURL_RC=0
CURL_CODE="403"
run_outcome 124 0
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "HTTP 403 PATCH must still re-queue, got: ${CALLS[*]:-nothing}"
case "${LOGS[0]:-}" in
  WARNING:*403*) ;;
  *) ac_fail "HTTP 403 must log a WARNING naming 403, got: ${LOGS[*]:-nothing}" ;;
esac
ac_log "AC 5b OK"

# no_result (harness death, not a wall-clock timeout) stays on this agent.
ac_log "AC 5c: subtype no_result without rc 124 keeps today's behaviour"
DIAG_NO_RESULT="$TMP_DIR/no-result.json"
printf '%s\n' '{"type":"result","subtype":"no_result","session_id":"s","num_turns":0}' > "$DIAG_NO_RESULT"
FAKE_LOGIN="dev-bot"
DEV_ESCALATE_TO="dev-grok-bot"
export DEV_ESCALATE_TO
CURL_RC=0
CURL_CODE="201"
run_outcome 0 0 "$DIAG_NO_RESULT"
ac_has_call_matching "issue_requeue ${ISSUE} no_result " \
  || ac_fail "no_result attempt 0 must re-queue, got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "escalated to"; then
  ac_fail "no_result must not escalate"
fi
assert_no_patch
run_outcome 0 2 "$DIAG_NO_RESULT"
ac_has_call_matching "issue_block ${ISSUE} no_push_after_3_attempts " \
  || ac_fail "no_result attempt 2 must block, got: ${CALLS[*]:-nothing}"
assert_no_patch
ac_log "AC 5c OK"

# ── 6. the Qwen jobspec names the escalation target ──────────────────────────
ac_log "AC 6: agents-dev-qwen.hcl sets DEV_ESCALATE_TO = dev-grok-bot"
grep -Eq 'DEV_ESCALATE_TO[[:space:]]*=[[:space:]]*"dev-grok-bot"' "$JOBSPEC" \
  || ac_fail 'jobspec must set DEV_ESCALATE_TO = "dev-grok-bot"'
# The one-line comment names this issue. nomad job validate runs in CI
# (.woodpecker/nomad-validate.yml) over every nomad/jobs/*.hcl.
grep -F '#1986' "$JOBSPEC" >/dev/null \
  || ac_fail "jobspec comment must name #1986"
# The Grok job must not escalate to itself.
if grep -Eq 'DEV_ESCALATE_TO[[:space:]]*=' "$REPO_ROOT/nomad/jobs/agents-dev-grok.hcl"; then
  ac_fail "agents-dev-grok.hcl must leave DEV_ESCALATE_TO unset"
fi
ac_log "AC 6 OK"

ac_pass
