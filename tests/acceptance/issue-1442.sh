#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1442.sh
#
# Issue #1442: no_push_outcome only re-queued error_max_turns and rc 124.
# Every other no-push — including dsh subtype=no_result (the harness never
# wrote a normal result row: server/harness death, not "agent chose not to
# push") — called issue_block, even with a good spec. Observed: #1186
# (no_result, 0 tokens, 14s), #1255, #1409 (no_result, 22 turns, then llama
# 503 mid-session). Operator had to put the issues back on backlog by hand.
#
# Fix: no_push_outcome() treats subtype=no_result like the timeout path —
# sets requeue_reason=no_result, then the existing attempt budget applies
# (attempt < 2 → issue_requeue; attempt >= 2 → issue_block with
# no_push_after_3_attempts). The timeout (rc 124) and error_max_turns paths
# are unchanged, and rc 124 still wins when both a timeout and a no_result
# row are present. Other subtypes with no requeue_reason still issue_block
# "no_push".
#
# Acceptance (self-contained — issue_block/issue_requeue are stubbed in
# process and synthetic diagnostic files are fed to the decision function):
#   1. subtype=no_result, attempt 0 → issue_requeue ... no_result, never
#      issue_block
#   2. subtype=no_result, attempt 1 → still issue_requeue (the cap is the
#      third consecutive resource-limit exit)
#   3. subtype=no_result, attempt >= 2 → issue_block no_push_after_3_attempts,
#      never a requeue
#   4. rc 124 wins over a no_result row when both are present (the timeout is
#      the more recent event)
#   5. multi-line streams — a no_result result row is detected whether it is
#      the only row (single-object nudge shape) or the LAST result row
#      (#1409-style stream with a llama 503 after 22 turns)
#   6. unchanged behaviour (regression): error_max_turns → requeue,
#      rc 124 → requeue timeout, rc 124 wins over error_max_turns, and every
#      other no-push reason → issue_block "no_push" (the no_push_after_3_
#      attempts reason only fires for resource-limit exits)
#
# Read-only: no live forge, no agent started. dev-agent.sh and the like
# cannot be sourced (top-level executables that would run the whole agent),
# so no_push_outcome is extracted from the checkout with awk — the same
# approach as tests/acceptance/issue-1164-requeue-on-resource-limit.sh.
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

ISSUE=1442
# no_push_outcome() interpolates the branch name into its messages.
BRANCH="fix/issue-${ISSUE}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Stubs: record every lifecycle call with its full argument list ───────────
CALLS=()
issue_block()   { CALLS+=("issue_block $*"); }
issue_requeue() { CALLS+=("issue_requeue $*"); }
forge_api()     { :; }  # defensive: the extracted function must not need it

# ── Extract no_push_outcome() from dev-agent.sh ───────────────────────────────
# The function is extracted by header — ac_extract_fn() takes `name() {`
# to the next column-0 closing brace, as issue-1164 does.
fn_body="$(ac_extract_fn no_push_outcome "$TARGET")"
[ -n "$fn_body" ] || ac_fail "could not locate no_push_outcome() in dev/dev-agent.sh"
eval "$fn_body"
type no_push_outcome >/dev/null 2>&1 \
  || ac_fail "no_push_outcome() did not evaluate to a function"

# ── Synthetic diagnostic files (real stream-json shapes) ──────────────────────
# #1186-style server/harness death: 0 tokens, ~14s, no normal result row —
# the terminal row carries subtype no_result.
DIAG_NO_RESULT_OBJ="$TMP_DIR/noreresult-obj.json"
cat > "$DIAG_NO_RESULT_OBJ" <<'EOF'
{"type":"result","subtype":"no_result","session_id":"s1","num_turns":0,"duration_ms":14000,"total_cost_usd":0.0,"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

# #1409-style llama 503 mid-session: multi-line stream whose LAST result row
# is no_result after 22 turns.
DIAG_NO_RESULT_STREAM="$TMP_DIR/noreresult-stream.jsonl"
cat > "$DIAG_NO_RESULT_STREAM" <<'EOF'
{"type":"system","subtype":"init","session_id":"s2","model":"test/model"}
{"type":"assistant","session_id":"s2","message":{"content":[{"type":"text","text":"working"}]}}
{"type":"result","subtype":"no_result","session_id":"s2","num_turns":22,"duration_ms":860000,"total_cost_usd":0.8,"usage":{"input_tokens":12000,"output_tokens":400,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

# A run that finished with a normal result row but pushed nothing — the
# non-resource-limit no_push case that must keep blocking.
DIAG_SUCCESS="$TMP_DIR/success.json"
cat > "$DIAG_SUCCESS" <<'EOF'
{"type":"result","subtype":"success","session_id":"s3","num_turns":3,"duration_ms":1000,"total_cost_usd":0.1,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

# error_max_turns fixture — the path that must be unchanged by this fix.
DIAG_MAX_TURNS_OBJ="$TMP_DIR/maxturns-obj.json"
cat > "$DIAG_MAX_TURNS_OBJ" <<'EOF'
{"type":"result","subtype":"error_max_turns","session_id":"s4","num_turns":60,"duration_ms":1000,"total_cost_usd":1.0,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# A requeue happened with exactly the given reason, and issue_block never fired.
assert_requeue() {
  local diag="$1" rc="$2" attempt="$3" reason="$4" what="$5"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" "$attempt" "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_block "; then
    ac_fail "no-push exit must NOT call issue_block (${what})"
  fi
  # Trailing space: the recorded reason must be exactly `$reason` (the block
  # path is the only thing that could otherwise carry a longer reason).
  ac_has_call_matching "issue_requeue ${ISSUE} ${reason} " \
    || ac_fail "expected issue_requeue ${ISSUE} ${reason}, got: ${CALLS[*]:-nothing} (${what})"
}

# A block happened with exactly the given reason, and issue_requeue never fired.
assert_block_reason() {
  local diag="$1" rc="$2" attempt="$3" reason="$4" what="$5"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" "$attempt" "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_requeue "; then
    ac_fail "attempt $attempt with reason ${reason} must NOT requeue (${what})"
  fi
  ac_has_call_matching "issue_block ${ISSUE} ${reason} " \
    || ac_fail "expected issue_block ${ISSUE} ${reason}, got: ${CALLS[*]:-nothing} (${what})"
}

# ── 1. subtype=no_result, attempt 0 → issue_requeue no_result ─────────────────
assert_requeue "$DIAG_NO_RESULT_OBJ" 0 0 "no_result" \
  "single object, subtype no_result, attempt 0"

# ── 2. subtype=no_result, attempt 1 → still requeue (cap is the 3rd exit) ───
assert_requeue "$DIAG_NO_RESULT_OBJ" 0 1 "no_result" \
  "single object, subtype no_result, attempt 1"

# ── 3. subtype=no_result, attempt >= 2 → issue_block no_push_after_3_attempts ─
assert_block_reason "$DIAG_NO_RESULT_OBJ" 0 2 "no_push_after_3_attempts" \
  "subtype no_result, attempt 2 (third exit)"
assert_block_reason "$DIAG_NO_RESULT_STREAM" 0 3 "no_push_after_3_attempts" \
  "subtype no_result, attempt 3"

# ── 4. rc 124 wins over no_result when both signals are present ───────────────
CALLS=()
no_push_outcome "$ISSUE" "$DIAG_NO_RESULT_OBJ" 124 0 "$NO_PUSH_TEXT"
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "rc 124 must win over a no_result row (the timeout is the more recent event)"
if ac_has_call_matching "issue_requeue ${ISSUE} no_result "; then
  ac_fail "rc 124 must be reported as 'timeout', not 'no_result'"
fi

# ── 5. multi-line stream: the LAST result row (no_result) is what counts ─────
assert_requeue "$DIAG_NO_RESULT_STREAM" 0 0 "no_result" \
  "multi-line stream, last result row no_result (#1409-style)"

# ── 6. regression: the #1164 paths are unchanged by this fix ──────────────────

# 6a. error_max_turns still requeues with its own reason.
assert_requeue "$DIAG_MAX_TURNS_OBJ" 0 0 "error_max_turns" \
  "subtype error_max_turns, attempt 0"

# 6b. rc 124 with no diag file at all still requeues timeout.
assert_requeue "$TMP_DIR/does-not-exist.json" 124 0 "timeout" \
  "rc 124 with no diag file"

# 6c. rc 124 still wins over error_max_turns when both are present.
CALLS=()
no_push_outcome "$ISSUE" "$DIAG_MAX_TURNS_OBJ" 124 0 "$NO_PUSH_TEXT"
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "rc 124 must win over an error_max_turns row (unchanged)"
if ac_has_call_matching "issue_requeue ${ISSUE} error_max_turns "; then
  ac_fail "rc 124 must be reported as 'timeout', not 'error_max_turns'"
fi

# 6d. a successful run that pushed nothing still blocks with plain no_push.
CALLS=()
no_push_outcome "$ISSUE" "$DIAG_SUCCESS" 0 0 "$NO_PUSH_TEXT"
if ac_has_call_matching "issue_requeue "; then
  ac_fail "a successful run that pushed nothing must NOT requeue"
fi
ac_has_call_matching "issue_block ${ISSUE} no_push " \
  || ac_fail "expected issue_block ${ISSUE} no_push, got: ${CALLS[*]:-nothing}"

# 6e. the no_push_after_3_attempts cap only applies to resource-limit exits:
#     a non-resource-limit no_push on attempt 2 stays plain no_push.
CALLS=()
no_push_outcome "$ISSUE" "$DIAG_SUCCESS" 0 2 "$NO_PUSH_TEXT"
ac_has_call_matching "issue_block ${ISSUE} no_push " \
  || ac_fail "a non-resource-limit no_push on attempt 2 must stay 'no_push'"
if ac_has_call_matching "no_push_after_3_attempts"; then
  ac_fail "no_push_after_3_attempts must only fire for resource-limit exits (no_result included)"
fi

ac_pass
