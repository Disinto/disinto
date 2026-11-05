#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2122.sh
#
# Issue #2122: feat(dev): a merge refused by the wall tells the owner.
# pr_merge's 405 branch now calls wall_notice_once (lib/wall-notice.sh, #2121)
# when that module is sourced, and dev/dev-poll.sh sources it so the dev merge
# path (try_direct_merge and the merge-ready sweep) wires it in. Callers that
# do not source lib/wall-notice.sh behave exactly as before: pr_merge's return
# codes and _PR_MERGE_ERROR are unchanged.
#
# Acceptance (hermetic — curl/forge_api stubbed, no live services):
#   1. With a stub wall_notice_once that records its arguments, pr_merge 7
#      returns 2 and the stub got "7" and the PR JSON from the 405 branch's GET.
#   2. Without the stub: pr_merge 7 still returns 2, _PR_MERGE_ERROR and the
#      head SHA are identical to before — nothing else changes.
#   3. dev/dev-poll.sh sources lib/wall-notice.sh; bash -n passes for
#      lib/pr-lifecycle.sh and dev/dev-poll.sh.
#   4. tests/acceptance/issue-1090-merge-block-reporting.sh still passes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep

PROJECT_NAME="issue2122test"
PRIMARY_BRANCH="main"
FORGE_TOKEN="test-token"
FORGE_API="http://forge.test/api/v1"
export PROJECT_NAME PRIMARY_BRANCH FORGE_TOKEN FORGE_API

HEAD_SHA="deadbeef00112233445566778899aabbccddeeff"
PR_JSON='{"number":7,"merged":false,"head":{"ref":"fix/issue-7","sha":"deadbeef00112233445566778899aabbccddeeff"}}'
BODY='{"message":"not allowed to merge [reason: only an administrator can merge protected files]"}'
EXPECTED_ERROR="blocked (HTTP 405): ${BODY}"

LOG_FILE="$(mktemp)"
CALLS_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE" "$CALLS_FILE"' EXIT

# log() — capture pr-lifecycle's _prl_log output (defined before sourcing).
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

# Stubs: the merge POST answers 405 (curl output mirrors
# `curl -s -w "\n%{http_code}"`: body, newline, HTTP code); the forge GET for
# the PR answers with PR_JSON (merged:false), branch protection reports no
# required status checks so _PRL_MERGE_DETAIL stays empty.
forge_api() {
  local path="$2"
  case "$path" in
    "/pulls/7")
      printf '%s' "$PR_JSON"
      ;;
    "/branch_protections/main")
      printf '{"enable_status_check":false}'
      ;;
    *)
      printf 'null'
      ;;
  esac
}

curl() {
  printf '%s\n405\n' "$BODY"
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ci-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pr-lifecycle.sh"

# ── 1. With a stub wall_notice_once: pr_merge 7 returns 2 and the stub
#    receives the PR number and the PR JSON ───────────────────────────────────
wall_notice_once() {
  printf '%s\t%s\n' "$1" "$2" >> "$CALLS_FILE"
}

rc=0
pr_merge 7 || rc=$?
ac_assert_eq "$rc" "2" "pr_merge must still return 2 (blocked) on HTTP 405, got $rc"

if ! grep -qF "$(printf '%s\t%s' '7' "$PR_JSON")" "$CALLS_FILE"; then
  ac_fail "the wall_notice_once stub must be called with 7 and the PR JSON, got: $(cat "$CALLS_FILE")"
fi

# ── 2. Without the stub: same return code, nothing else changes ──────────────
rc=0
out=$(
  unset -f wall_notice_once
  rc_inner=0
  pr_merge 7 || rc_inner=$?
  printf '%s\n%s\n%s\n' "$rc_inner" "$_PR_MERGE_ERROR" "$_PR_MERGE_HEAD_SHA"
)
rc2=$(printf '%s\n' "$out" | head -n1)
err2=$(printf '%s\n' "$out" | sed -n '2p')
head2=$(printf '%s\n' "$out" | sed -n '3p')
ac_assert_eq "$rc2" "2" "pr_merge without wall_notice_once must still return 2, got $rc2"
ac_assert_eq "$err2" "$EXPECTED_ERROR" "pr_merge without wall_notice_once must keep the exact _PR_MERGE_ERROR, got: $err2"
ac_assert_eq "$head2" "$HEAD_SHA" "pr_merge must still expose the PR head SHA on a blocked merge"

if ! grep -qF "$(printf '%s\t%s' '7' "$PR_JSON")" "$CALLS_FILE"; then
  ac_fail "the stub call from AC1 must be the only wall_notice_once call recorded"
fi
rc_lines=$(wc -l < "$CALLS_FILE" | tr -d '[:space:]')
ac_assert_eq "$rc_lines" "1" "pr_merge must call wall_notice_once exactly once when it is defined"

# ── 3. Wiring: dev-poll sources lib/wall-notice.sh; both files parse ─────────
sources=$(grep -c 'lib/wall-notice\.sh' "$REPO_ROOT/dev/dev-poll.sh" || true)
if [ "${sources:-0}" -lt 1 ]; then
  ac_fail "dev/dev-poll.sh must source lib/wall-notice.sh (found $sources matches)"
fi
bash -n "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "bash -n fails on lib/pr-lifecycle.sh"
bash -n "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "bash -n fails on dev/dev-poll.sh"

# ── 4. The existing merge-block acceptance test still passes ─────────────────
out1090=$(bash "$REPO_ROOT/tests/acceptance/issue-1090-merge-block-reporting.sh" 2>&1) || {
  ac_fail "issue-1090-merge-block-reporting.sh must still pass: $out1090"
}
ac_assert_eq "$out1090" "PASS" "issue-1090-merge-block-reporting.sh must print PASS"

ac_pass
