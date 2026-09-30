#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1646.sh
#
# Issue #1646: count failed attempts from the tape so the retry cap fires.
#
# An attempt that pushed nothing left ATTEMPT at 0 — ATTEMPT counts the remote
# fix/issue-N* branches, which only grows when a branch is actually pushed.
# So the no-push retry cap (no_push_after_3_attempts, firing at attempt >= 2)
# never triggered: e.g. #1615 timed out and re-queued six times, stalling the
# queue for seven hours.
#
# Fix: dev_failed_attempts ID counts the proposal's FAILED attempts from the
# tape — outcome records whose merged is 0 or false and whose rejected is not
# 1 or true. TAPE_RUN_ATTEMPTS is now DEV_FAILED_ATTEMPTS + 1 (1-based), and
# no_push_outcome is fed DEV_FAILED_ATTEMPTS instead of ATTEMPT. The old
# TAPE_RUN_ATTEMPTS="${ATTEMPT:0:0}" block (which crashed under set -u in
# recovery mode where ATTEMPT is unset) is gone. Branch naming from ATTEMPT is
# unchanged; only the tape attempt count and the retry-cap source change.
#
# Acceptance (self-contained — the decision function is extracted from
# dev-agent.sh and the tape is a fixture under $TMP_DIR; no live forge, no
# agent started):
#   1. a fixture tape with two {merged:0, ci_green:0} outcomes under proposal
#      p1 -> dev_failed_attempts p1 == 2
#   2. {merged:1} and {rejected:1} outcomes are NOT counted; dev_failed_attempts
#      "" and a missing tape -> 0
#   3. no_push_outcome with attempt 2 and rc 124 calls the stubbed issue_block
#      with no_push_after_3_attempts
#   4. the ATTEMPT:0:0 block is gone (grep -c 'ATTEMPT:0:0' dev/dev-agent.sh == 0)
#
# Read-only: no live forge, no agent started. dev-agent.sh cannot be sourced
# (a top-level executable that would run the whole agent), so both the no-push
# decision function and the tape helper are extracted with ac_extract_fn() and
# eval'd in-process — the same approach as issue-1164 and issue-1442.
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

ac_require_cmd bash jq awk

ISSUE=1646
BRANCH="fix/issue-${ISSUE}"
# shellcheck disable=SC2034 # consumed by the sourced no-push harness ac_assert_* functions
NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"

# ── Extraction (the shared no-push harness owns $TMP_DIR, its EXIT trap, and
#    the issue_block()/issue_requeue()/forge_api() stubs) ────────────────────────
ac_no_push_stub
ac_load_decision_fn "$TARGET" "no_push_outcome"
ac_load_decision_fn "$TARGET" "dev_failed_attempts"

# ── Fixture 1: two no-push outcomes under p1 — the core counting case ─────────
TAPE1="$TMP_DIR/tape-1"
mkdir -p "$TAPE1"
printf '%s\n' \
  '{"type":"outcome","t":"2026-09-30T00:00:00Z","proposal_id":"p1","bits":{"merged":0,"ci_green":0},"numbers":{"review_rounds":0},"children":{},"payloads":[]}' \
  '{"type":"outcome","t":"2026-09-30T00:01:00Z","proposal_id":"p1","bits":{"merged":0,"ci_green":0},"numbers":{"review_rounds":0},"children":{},"payloads":[]}' \
  > "$TAPE1/tape.jsonl"
# shellcheck disable=SC2034 # consumed by the eval'd dev_failed_attempts
TAPE_DIR="$TAPE1"
out="$(dev_failed_attempts "p1")"
ac_assert_eq "$out" "2" "two {merged:0,ci_green:0} outcomes under p1 (got: '$out')"

# ── Fixture 2: merged:1 and rejected:1 outcomes must NOT be counted ───────────
TAPE2="$TMP_DIR/tape-2"
mkdir -p "$TAPE2"
printf '%s\n' \
  '{"type":"outcome","t":"2026-09-30T00:02:00Z","proposal_id":"q1","bits":{"merged":1,"ci_green":1},"numbers":{"review_rounds":1},"children":{},"payloads":[]}' \
  '{"type":"outcome","t":"2026-09-30T00:03:00Z","proposal_id":"q1","bits":{"merged":0,"ci_green":0,"rejected":1},"numbers":{"review_rounds":2},"children":{},"payloads":[]}' \
  > "$TAPE2/tape.jsonl"
# shellcheck disable=SC2034 # consumed by the eval'd dev_failed_attempts
TAPE_DIR="$TAPE2"
out="$(dev_failed_attempts "q1")"
ac_assert_eq "$out" "0" "{merged:1} and {rejected:1} outcomes must not count (got: '$out')"

# ── Empty id and a missing tape -> 0 ───────────────────────────────────────────
out="$(dev_failed_attempts "")"
ac_assert_eq "$out" "0" 'empty id must print 0 (got: '"'"'"$out"'"'"')'

TAPE3="$TMP_DIR/tape-missing"
mkdir -p "$TAPE3"
# shellcheck disable=SC2034 # consumed by the eval'd dev_failed_attempts
TAPE_DIR="$TAPE3"
out="$(dev_failed_attempts "q1")"
ac_assert_eq "$out" "0" "missing tape must print 0 (got: '$out')"

# ── retry cap: attempt 2 + rc 124 (timeout) -> issue_block no_push_after_3_attempts ─
# A wall-clock timeout (rc 124) is the more recent resource-limit signal and
# wins the requeue reason; at attempt >= 2 the cap fires instead of re-queueing.
DIAG_TIMEOUT="$TMP_DIR/timeout-result.json"
printf '%s\n' \
  '{"type":"system","subtype":"init","session_id":"s-t","model":"test/model"}' \
  '{"type":"result","subtype":"no_result","session_id":"s-t","num_turns":30,"duration_ms":7200000,"total_cost_usd":1.2,"usage":{"input_tokens":90000,"output_tokens":1500}}' \
  > "$DIAG_TIMEOUT"
ac_assert_block_reason "$DIAG_TIMEOUT" 124 2 "no_push_after_3_attempts" \
  "attempt 2 with rc 124 (third consecutive timeout) must block no_push_after_3_attempts"

# ── the old ATTEMPT:0:0 block is gone ──────────────────────────────────────────
hits="$(grep -c 'ATTEMPT:0:0' "$TARGET" || true)"
ac_assert_eq "$hits" "0" "ATTEMPT:0:0 block must be removed (found: '$hits')"

ac_pass
