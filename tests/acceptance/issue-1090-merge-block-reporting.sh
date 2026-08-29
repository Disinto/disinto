#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1090-merge-block-reporting.sh
#
# Issue #1090: when the direct merge of an approved PR is rejected by forge
# with HTTP 405 (e.g. required status checks not satisfied), dev-poll retried
# on every cycle forever and logged an identical line truncated at 200 chars,
# so the real reason was lost:
#   ...{"message":"not allowed to merge [reason: Not all
#
# Acceptance (self-contained — curl/forge_api stubbed, no live services):
#   1. On a 405 whose body is LONGER than the old 200-char cut-off, pr_merge
#      reports the FULL untruncated forge body (in _PR_MERGE_ERROR and in the
#      log) and sets _PR_MERGE_HEAD_SHA.
#   2. When branch protection declares required status check contexts, the
#      failure names the specific context(s) not satisfied on the head (the
#      failing one and the not-yet-reported one) via _PR_MERGE_MISSING_CONTEXTS
#      and appends them to the logged message.
#   3. N identical consecutive failures (same PR + head SHA + reason) escalate
#      exactly once and then stop ("skip") instead of retrying forever; a new
#      head SHA or a changed reason resets the counter; a successful merge
#      clears the state.
#   4. dev-poll consumes the state machine and escalation helper (wiring), and
#      pr-lifecycle no longer truncates the forge body (no `${body:0:200}`).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

# ── Isolated state + env ─────────────────────────────────────────────────────
PROJECT_NAME="issue1090test"
PRIMARY_BRANCH="main"
FORGE_TOKEN="test-token"
FORGE_API="http://forge.test/api/v1"
MERGE_BLOCK_RETRY_LIMIT=2
export PROJECT_NAME PRIMARY_BRANCH FORGE_TOKEN FORGE_API MERGE_BLOCK_RETRY_LIMIT

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

HEAD_SHA="deadbeef00112233445566778899aabbccddeeff"

# A realistic forge 405 body, deliberately longer than the old 200-char cut.
LONG_BODY='{"message":"not allowed to merge [reason: Not all required status checks have been met: the required context ci/woodpecker/push/ci is failing on the head commit, and the required context ci/woodpecker/push/security-scan has not been reported yet; branch protection requires all listed contexts to pass]"}'

if [ "${#LONG_BODY}" -le 200 ]; then
  ac_fail "fixture 405 body must exceed the old 200-char truncation limit (got ${#LONG_BODY} chars)"
fi

# log() — capture pr-lifecycle's _prl_log output (defined before sourcing).
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

# ── Stubs: forge_api (GET endpoints) + curl (the merge POST) ────────────────
forge_api() {
  local path="$2"
  case "$path" in
    "/pulls/42")
      printf '{"number":42,"merged":false,"head":{"ref":"fix/issue-42","sha":"%s"}}' "$HEAD_SHA"
      ;;
    "/branch_protections/main")
      printf '{"enable_status_check":true,"status_check_contexts":["ci/woodpecker/pr/ci","ci/woodpecker/push/ci","ci/woodpecker/push/security-scan"]}'
      ;;
    "/commits/${HEAD_SHA}/status")
      printf '{"state":"failure","statuses":[{"id":1,"context":"ci/woodpecker/pr/ci","status":"success"},{"id":2,"context":"ci/woodpecker/push/ci","status":"failure"},{"id":3,"context":"ci/woodpecker/push/security-scan","status":"pending"}]}'
      ;;
    *)
      printf 'null'
      ;;
  esac
}

# The merge POST: body, then a newline, then the HTTP code (mirrors
# `curl -s -w "\n%{http_code}"` which pr_merge parses with tail -1 / sed '$d').
curl() {
  printf '%s\n405\n' "$LONG_BODY"
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ci-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pr-lifecycle.sh"

# ── 1. Full untruncated 405 body + head SHA ─────────────────────────────────
rc=0
pr_merge 42 || rc=$?
ac_assert_eq "$rc" "2" \
  "pr_merge must return 2 (blocked) on HTTP 405, got $rc"

EXPECTED_DETAIL=" [required status checks unsatisfied: ci/woodpecker/push/ci, ci/woodpecker/push/security-scan]"
EXPECTED_ERROR="blocked (HTTP 405): ${LONG_BODY}${EXPECTED_DETAIL}"
ac_assert_eq "$_PR_MERGE_ERROR" "$EXPECTED_ERROR" \
  "_PR_MERGE_ERROR must carry the full untruncated forge body plus the unsatisfied contexts"

ac_assert_eq "$_PR_MERGE_HEAD_SHA" "$HEAD_SHA" \
  "pr_merge must expose the PR head SHA on a blocked merge"

if ! grep -Fq "$LONG_BODY" "$LOG_FILE"; then
  ac_fail "the log must contain the full, untruncated forge 405 body"
fi
grep -q 'ci/woodpecker/push/ci' "$LOG_FILE" \
  || ac_fail "the log must name the failing required check (ci/woodpecker/push/ci)"
grep -q 'ci/woodpecker/push/security-scan' "$LOG_FILE" \
  || ac_fail "the log must name the unreported required check (ci/woodpecker/push/security-scan)"

ac_assert_eq "$_PR_MERGE_MISSING_CONTEXTS" "ci/woodpecker/push/ci, ci/woodpecker/push/security-scan" \
  "pr_merge must expose the unsatisfied required check contexts"

# ── 2. Retry limit: N identical failures → escalate once, then stop ─────────
REASON="$_PR_MERGE_ERROR"

D1=$(pr_merge_block_record 42 "$HEAD_SHA" "$REASON")
ac_assert_eq "$D1" "retry" "failure 1 of limit 2 must be 'retry'"

D2=$(pr_merge_block_record 42 "$HEAD_SHA" "$REASON")
ac_assert_eq "$D2" "escalate" "failure 2 (== limit) must be 'escalate'"

if pr_merge_block_escalated 42 "$HEAD_SHA"; then
  : # expected
else
  ac_fail "after escalation, pr_merge_block_escalated must report PR 42 escalated for $HEAD_SHA"
fi

D3=$(pr_merge_block_record 42 "$HEAD_SHA" "$REASON")
ac_assert_eq "$D3" "skip" "failure 3 (already escalated) must be 'skip', not another escalate"

D4=$(pr_merge_block_record 42 "$HEAD_SHA" "$REASON")
ac_assert_eq "$D4" "skip" "'skip' must be sticky — no re-escalation on later identical failures"

# A new head SHA or a changed reason resets the counter.
D5=$(pr_merge_block_record 42 "0000000000000000000000000000000000000000" "$REASON")
ac_assert_eq "$D5" "retry" "a new head SHA must reset the counter"

D6=$(pr_merge_block_record 42 "0000000000000000000000000000000000000000" "a different failure reason")
ac_assert_eq "$D6" "retry" "a changed failure reason must reset the counter"

# A successful merge clears the state.
pr_merge_block_clear 42
if pr_merge_block_escalated 42; then
  ac_fail "pr_merge_block_clear must remove the escalated state"
fi

# An explicit per-call limit is honored (limit 1 → first failure escalates).
D7=$(pr_merge_block_record 42 "$HEAD_SHA" "r1" 1)
ac_assert_eq "$D7" "escalate" "with limit 1, the first failure must escalate"

# ── 3. Wiring: dev-poll consumes the state machine; no truncation left ──────
grep -q 'pr_merge_block_record' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll does not use pr_merge_block_record"
grep -q 'pr_merge_block_escalated' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll does not consult pr_merge_block_escalated"
grep -q 'pr_merge_block_clear' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll does not clear merge-block state on a successful merge"
grep -q 'escalate_merge_blocked_pr' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll is missing escalate_merge_blocked_pr"
grep -q 'ci_unsatisfied_required_contexts' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "lib/pr-lifecycle.sh does not name the unsatisfied required checks"
if grep -q 'body:0:200' "$REPO_ROOT/lib/pr-lifecycle.sh"; then
  ac_fail "lib/pr-lifecycle.sh still truncates the forge error body at 200 chars"
fi

pr_merge_block_clear 42
ac_pass
