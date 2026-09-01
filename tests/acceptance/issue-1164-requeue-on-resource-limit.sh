#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1164-requeue-on-resource-limit.sh
#
# Issue #1164: when a dev-agent session exits on a resource limit (max turns
# or the wall-clock timeout) without pushing, dev/dev-agent.sh called
# issue_block "$ISSUE" "no_push" unconditionally — labeling the issue
# "blocked" (not claimable) and silently stopping the queue until a human
# relabeled it. A resource limit is a TRANSIENT failure, not a reason the
# issue can never be worked.
#
# The fix: the no-push path decides via no_push_outcome() —
#   - result subtype error_max_turns, or agent_run rc 124 (wall-clock
#     timeout) → issue_requeue: back to the claimable backlog with a
#     diagnostic "Re-queued" comment
#   - third consecutive resource-limit exit (attempt >= 2, 0-indexed count
#     of existing fix/issue-N* branches) → issue_block with reason
#     no_push_after_3_attempts (a human decision is needed)
#   - anything else → issue_block "no_push" exactly as before
#
# Acceptance (self-contained — issue_block and issue_requeue are stubbed
# in-process; synthetic diagnostic files are fed to the decision function):
#   1. error_max_turns result (single object or multi-line stream) →
#      issue_requeue ... error_max_turns, never issue_block
#   2. agent_run rc 124 → issue_requeue ... timeout — both with a truncated
#      diag file (watchdog kill mid-write leaves no result row) and with no
#      diag file at all
#   3. rc 124 wins over an error_max_turns row when both are present (the
#      timeout is the more recent event)
#   4. every other no-push reason (success subtype, non-timeout exit code) →
#      issue_block ... no_push, never a requeue
#   5. the third consecutive resource-limit exit (attempt >= 2) blocks with
#      no_push_after_3_attempts; attempts 1-2 still requeue
#   6. review/review-pr.sh review_run_and_parse(): an agent_run rc 124
#      (wall-clock timeout) with no valid output does NOT abort the script —
#      it posts the "Review failed (review timed out ...)" error comment to
#      the PR and returns 1, so a timed-out review is visible instead of a
#      silent hang
#   7. the same function with rc 0 + a valid verdict returns 0 and posts no
#      error comment; a non-timeout crash (rc 3) reports "agent_run rc 3",
#      not a timeout; a valid verdict posted before a timeout is still
#      honoured
#
# Read-only: no live forge, no agent started. dev-agent.sh and review-pr.sh
# cannot be sourced (top-level executables that would run the whole agent),
# so no_push_outcome and review_run_and_parse are extracted from the
# checkout with awk — the same approach as
# tests/acceptance/issue-1130-stale-sweep-merged-pr.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

ISSUE=1164
# no_push_outcome() interpolates the branch name into its messages.
BRANCH="fix/issue-${ISSUE}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Stubs: record every lifecycle call with its full argument list ─────────
CALLS=()
issue_block()   { CALLS+=("issue_block $*"); }
issue_requeue() { CALLS+=("issue_requeue $*"); }
forge_api()     { :; }  # defensive: the extracted function must not need it

# ── Extract no_push_outcome() from dev-agent.sh ─────────────────────────────
# dev-agent.sh is a top-level executable (sourcing it would run the whole
# agent), so the function is extracted by header — ac_extract_fn() takes
# `name() {` to the next column-0 closing brace — as issue-1130 does.
fn_body="$(ac_extract_fn no_push_outcome "$TARGET")"
[ -n "$fn_body" ] || ac_fail "could not locate no_push_outcome() in dev/dev-agent.sh"
eval "$fn_body"
type no_push_outcome >/dev/null 2>&1 \
  || ac_fail "no_push_outcome() did not evaluate to a function"

# ── Synthetic diagnostic files (real stream-json shapes) ────────────────────
DIAG_MAX_TURNS_OBJ="$TMP_DIR/maxturns-obj.json"
cat > "$DIAG_MAX_TURNS_OBJ" <<'EOF'
{"type":"result","subtype":"error_max_turns","session_id":"s1","num_turns":60,"duration_ms":1000,"total_cost_usd":1.0,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

# The production shape: init row, assistant rows, terminal result row.
DIAG_MAX_TURNS_STREAM="$TMP_DIR/maxturns-stream.jsonl"
cat > "$DIAG_MAX_TURNS_STREAM" <<'EOF'
{"type":"system","subtype":"init","session_id":"s2","model":"test/model"}
{"type":"assistant","session_id":"s2","message":{"content":[{"type":"text","text":"working"}]}}
{"type":"result","subtype":"error_max_turns","session_id":"s2","num_turns":60,"duration_ms":1000,"total_cost_usd":1.0,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

# Watchdog kill mid-write: the final line is truncated, no result row at all.
DIAG_TRUNCATED="$TMP_DIR/truncated.jsonl"
cat > "$DIAG_TRUNCATED" <<'EOF'
{"type":"system","subtype":"init","session_id":"s3","model":"test/model"}
{"type":"assistant","session_id":"s3","mess
EOF

DIAG_SUCCESS="$TMP_DIR/success.json"
cat > "$DIAG_SUCCESS" <<'EOF'
{"type":"result","subtype":"success","session_id":"s4","num_turns":3,"duration_ms":1000,"total_cost_usd":0.1,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"

# ── 1. error_max_turns → requeue, never block ───────────────────────────────
assert_requeue() {
  local diag="$1" rc="$2" attempt="$3" reason="$4" what="$5"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" "$attempt" "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_block "; then
    ac_fail "resource-limit exit must NOT call issue_block (${what})"
  fi
  # Trailing space: the recorded reason must be exactly `$reason`.
  ac_has_call_matching "issue_requeue ${ISSUE} ${reason} " \
    || ac_fail "expected issue_requeue ${ISSUE} ${reason}, got: ${CALLS[*]:-nothing} (${what})"
}

# 1a. Single-object diag file (nudge output shape).
assert_requeue "$DIAG_MAX_TURNS_OBJ" 0 0 "error_max_turns" \
  "single object, subtype error_max_turns"

# 1b. Multi-line stream — a naive whole-file `.subtype` read would see the
#     init row's subtype first and miss it; the last result row must win.
assert_requeue "$DIAG_MAX_TURNS_STREAM" 0 0 "error_max_turns" \
  "multi-line stream, subtype error_max_turns"

# 1c. Second attempt (attempt=1) still requeues — the cap is the third.
assert_requeue "$DIAG_MAX_TURNS_OBJ" 0 1 "error_max_turns" \
  "second attempt (attempt=1)"

# ── 2. rc 124 (wall-clock timeout) → requeue ────────────────────────────────
# 2a. Watchdog kill: truncated stream, no result row.
assert_requeue "$DIAG_TRUNCATED" 124 0 "timeout" \
  "rc 124 with a truncated diag file (no result row)"

# 2b. No diag file at all (crash before the write).
assert_requeue "$TMP_DIR/does-not-exist.json" 124 0 "timeout" \
  "rc 124 with no diag file"

# ── 3. rc 124 wins when both signals are present ────────────────────────────
CALLS=()
no_push_outcome "$ISSUE" "$DIAG_MAX_TURNS_OBJ" 124 0 "$NO_PUSH_TEXT"
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "rc 124 must win over an error_max_turns row (it is the more recent event)"
if ac_has_call_matching "issue_requeue ${ISSUE} error_max_turns "; then
  ac_fail "rc 124 must be reported as 'timeout', not 'error_max_turns'"
fi

# ── 4. Every other no-push reason → issue_block "no_push", unchanged ────────
assert_no_push_block() {
  local diag="$1" rc="$2" what="$3"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" 0 "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_requeue "; then
    ac_fail "non-resource-limit no_push must NOT requeue (${what})"
  fi
  # Trailing space: must be the plain "no_push" reason, not the
  # no_push_after_3_attempts one.
  ac_has_call_matching "issue_block ${ISSUE} no_push " \
    || ac_fail "expected issue_block ${ISSUE} no_push, got: ${CALLS[*]:-nothing} (${what})"
}

# 4a. Run finished successfully but pushed nothing.
assert_no_push_block "$DIAG_SUCCESS" 0 "result subtype success but no push"

# 4b. Non-timeout crash (rc 3), no result row.
assert_no_push_block "$DIAG_TRUNCATED" 3 "non-timeout exit code, no result row"

# ── 5. Retry cap: third consecutive resource-limit exit → block ─────────────
assert_block_after_3() {
  local diag="$1" rc="$2" what="$3"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" 2 "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_requeue "; then
    ac_fail "third resource-limit exit must NOT requeue (${what})"
  fi
  ac_has_call_matching "issue_block ${ISSUE} no_push_after_3_attempts " \
    || ac_fail "expected no_push_after_3_attempts, got: ${CALLS[*]:-nothing} (${what})"
}

# 5a. attempt=2 (the third attempt) with error_max_turns.
assert_block_after_3 "$DIAG_MAX_TURNS_OBJ" 0 "third attempt, subtype error_max_turns"

# 5b. attempt=2 (the third attempt) with a timeout.
assert_block_after_3 "$DIAG_TRUNCATED" 124 "third attempt, rc 124"

# 5c. An unrelated (non-resource-limit) exit on attempt 2 still blocks with
#     the plain no_push reason — the cap only applies to resource limits.
CALLS=()
no_push_outcome "$ISSUE" "$DIAG_SUCCESS" 0 2 "$NO_PUSH_TEXT"
ac_has_call_matching "issue_block ${ISSUE} no_push " \
  || ac_fail "a non-resource-limit no_push on attempt 2 must stay 'no_push', got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "no_push_after_3_attempts"; then
  ac_fail "no_push_after_3_attempts must only fire for resource-limit exits"
fi

# ── 6-7. review-pr.sh: timeout must reach the error-comment path ───────────
# review-pr.sh is a top-level executable too, so review_run_and_parse() is
# extracted the same way. Its mutating/external calls are stubbed:
# agent_run returns a per-case rc, curl records each call + body.
REVIEW_TARGET="$REPO_ROOT/review/review-pr.sh"
ac_assert_file "$REVIEW_TARGET" "review/review-pr.sh must exist"
review_fn_body="$(ac_extract_fn review_run_and_parse "$REVIEW_TARGET")"
[ -n "$review_fn_body" ] \
  || ac_fail "could not locate review_run_and_parse() in review/review-pr.sh"
eval "$review_fn_body"
type review_run_and_parse >/dev/null 2>&1 \
  || ac_fail "review_run_and_parse() did not evaluate to a function"

# Globals review-pr.sh would normally have set before calling the function.
# SC2034 on the ones below: they are consumed by the eval'd
# review_run_and_parse, which shellcheck cannot see through `eval`.
PR_NUMBER="$ISSUE"
# shellcheck disable=SC2034
PR_SHA="abcdef1234567890"
# shellcheck disable=SC2034
FORGE_TOKEN="test-token"
# shellcheck disable=SC2034
API="https://forge.example/api/repos/test/repo"
# shellcheck disable=SC2034
WORKTREE="$TMP_DIR/review-wt"
# shellcheck disable=SC2034
PROMPT="review prompt"
# shellcheck disable=SC2034
IS_RE_REVIEW=false
_AGENT_SESSION_ID=""
OUTPUT_FILE="$TMP_DIR/review-output.json"
CLAUDE_TIMEOUT=900

CURL_ARGS="$TMP_DIR/curl-args.log"
CURL_BODY="$TMP_DIR/curl-body.log"
# The agent_run stub emulates the real agent: before returning the configured
# rc it writes the (pre-decided) output file, so the function's opening
# `rm -f "$OUTPUT_FILE"` + "agent writes it during the run" sequence holds.
agent_run() {
  [ -n "${AGENT_STUB_OUTPUT:-}" ] && printf '%s' "$AGENT_STUB_OUTPUT" > "$OUTPUT_FILE"
  return "${AGENT_RUN_RC_STUB:-0}"
}
# curl runs in a pipeline subshell, so the stub records to files instead of a
# shell array. The body goes to its own file because jq -n emits
# pretty-printed, multi-line JSON.
curl() {
  local body
  body="$(cat)"
  printf '%s\n' "$*" >> "$CURL_ARGS"
  printf '%s\n' "$body" >> "$CURL_BODY"
  return 0
}
log()    { :; }
status() { :; }

# run_review <agent-run-rc> <output-file|-> — run the function, returning its
# rc via REVIEW_RC (guarded: a non-zero rc is the thing under test).
run_review() {
  local stub_rc="$1" out="$2"
  AGENT_RUN_RC_STUB="$stub_rc"
  if [ "$out" = "-" ]; then AGENT_STUB_OUTPUT=""; else AGENT_STUB_OUTPUT="$(cat "$out")"; fi
  : > "$CURL_ARGS"
  : > "$CURL_BODY"
  REVIEW_RC=0
  review_run_and_parse || REVIEW_RC=$?
}

# 6a. rc 124 + no output → return 1, error comment posted to the PR comments
#     endpoint, body names the timeout.
run_review 124 -
[ "$REVIEW_RC" -eq 1 ] \
  || ac_fail "timeout with no output must return 1, got ${REVIEW_RC}"
[ -s "$CURL_ARGS" ] \
  || ac_fail "timeout path must post the error comment (no curl call seen)"
CURL_LINE="$(tail -1 "$CURL_ARGS")"
BODY_TEXT="$(cat "$CURL_BODY" 2>/dev/null || true)"
case "$CURL_LINE" in
  *"/issues/${PR_NUMBER}/comments"*) ;;
  *) ac_fail "error comment must go to the PR comments endpoint, got: $CURL_LINE" ;;
esac
case "$BODY_TEXT" in
  *"review-error"*) ;;
  *) ac_fail "error comment must carry the review-error marker, got: $BODY_TEXT" ;;
esac
case "$BODY_TEXT" in
  *"timed out after ${CLAUDE_TIMEOUT}s"* | *"agent_run rc 124"*) ;;
  *) ac_fail "timeout comment must name the timeout (rc 124), got: $BODY_TEXT" ;;
esac

# 6b. rc 3 (non-timeout crash) + no output → return 1, comment reports the rc
#     but must NOT call it a timeout.
run_review 3 -
[ "$REVIEW_RC" -eq 1 ] || ac_fail "crash with no output must return 1, got ${REVIEW_RC}"
BODY_TEXT="$(cat "$CURL_BODY" 2>/dev/null || true)"
case "$BODY_TEXT" in
  *"agent_run rc 3"*) ;;
  *) ac_fail "crash comment must report 'agent_run rc 3', got: $BODY_TEXT" ;;
esac
case "$BODY_TEXT" in
  *"timed out"*) ac_fail "a non-timeout crash (rc 3) must not be reported as a timeout" ;;
esac

# 7a. rc 0 + a valid verdict → return 0, no error comment.
printf '{"verdict":"approve","verdict_reason":"ok","review_markdown":"LGTM"}' \
  > "$TMP_DIR/verdict-ok.json"
run_review 0 "$TMP_DIR/verdict-ok.json"
[ "$REVIEW_RC" -eq 0 ] || ac_fail "valid verdict must return 0, got ${REVIEW_RC}"
[ ! -s "$CURL_ARGS" ] && [ ! -s "$CURL_BODY" ] \
  || ac_fail "happy path must not post the error comment, saw: $(cat "$CURL_BODY" 2>/dev/null)"
[ -n "$REVIEW_JSON" ] || ac_fail "valid verdict must be captured in REVIEW_JSON"

# 7b. rc 124 but a valid verdict was already written → still honoured.
run_review 124 "$TMP_DIR/verdict-ok.json"
[ "$REVIEW_RC" -eq 0 ] \
  || ac_fail "a valid verdict written before the timeout must still be honoured, got ${REVIEW_RC}"
[ ! -s "$CURL_ARGS" ] && [ ! -s "$CURL_BODY" ] \
  || ac_fail "honoured verdict must not post the error comment, saw: $(cat "$CURL_BODY" 2>/dev/null)"

ac_pass
