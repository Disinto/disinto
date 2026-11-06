#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2158.sh
#
# Issue #2158: fix(dev): a merge the wall refuses waits for the owner, with
# no rebase session.
#
# Changes under test:
#   * pr_merge (lib/pr-lifecycle.sh) resets _PR_MERGE_WALLED=0 with the other
#     _PR_MERGE_* globals and sets it to 1 on HTTP 405 when the body contains
#     "Changed protected files" (the wall, #2120). The return code stays 2 and
#     _PR_MERGE_ERROR is unchanged.
#   * pr_walk_to_merge (APPROVE branch) ends with _PR_WALK_EXIT_REASON=walled
#     when the merge fails with _PR_MERGE_WALLED=1 — no rebase agent_run.
#   * dev/dev-agent.sh handles the walled reason before dev_walk_reason_terminal:
#     outcome "waiting_owner", the issue stays in progress, no issue_block.
#   * try_direct_merge (dev/dev-poll.sh) returns 2 on a walled merge without
#     pr_merge_block_record, without an escalation comment, and without the
#     `blocked` label.
#
# Acceptance (hermetic — curl/forge_api stubbed, no live services):
#   1. pr_merge with a 405 whose body is the wall's message returns 2 and
#      sets _PR_MERGE_WALLED=1.
#   2. The same with body {"message":"Please try again later"} returns 2 and
#      sets _PR_MERGE_WALLED=0. _PR_MERGE_ERROR is identical in both cases to
#      what it was before this change.
#   3. pr_walk_to_merge with CI green, review APPROVE and the wall's 405
#      returns 1 with _PR_WALK_EXIT_REASON=walled, and the stub agent_run that
#      records its calls is never called.
#   4. The same walk with the other 405 calls agent_run with a prompt
#      containing "approved but merge failed", as today.
#   5. try_direct_merge with the wall's 405 returns 2, leaves no
#      pr_merge_block_state file, and its curl stub sees no POST to
#      /issues/<n>/comments or /issues/<n>/labels.
#   6. In dev/dev-agent.sh the walled branch (outcome="waiting_owner") comes
#      before the issue_block call in the walk-failure branch.
#   7. bash -n (and shellcheck when available) is clean on the three files.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk
LIFECYCLE="$REPO_ROOT/lib/pr-lifecycle.sh"
AGENT="$REPO_ROOT/dev/dev-agent.sh"
POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$LIFECYCLE" "lib/pr-lifecycle.sh is present"
ac_assert_file "$AGENT" "dev/dev-agent.sh is present"
ac_assert_file "$POLL" "dev/dev-poll.sh is present"

PROJECT_NAME="issue2158test"
PRIMARY_BRANCH="main"
FORGE_TOKEN="test-token"
FORGE_API="http://forge.test/api/v1"
export PROJECT_NAME PRIMARY_BRANCH FORGE_TOKEN FORGE_API

PR_NUMBER=9
ISSUE_NUMBER=123
HEAD_SHA="deadbeef00112233445566778899aabbccddeeff"
PR_JSON='{"number":9,"merged":false,"head":{"ref":"fix/issue-9","sha":"deadbeef00112233445566778899aabbccddeeff"}}'
WALL_BODY='{"message":"not allowed to merge [reason: Changed protected files]"}'
RETRY_BODY='{"message":"Please try again later"}'

TMP_DIR="$(mktemp -d /tmp/acceptance-2158.XXXXXX)"
WORKTREE="$TMP_DIR/worktree"
AGENT_CALLS="$TMP_DIR/agent-calls"
TDM_LOG="$TMP_DIR/tdm-log"
TDM_RECORDS="$TMP_DIR/tdm-records"
TDM_CURL="$TMP_DIR/tdm-curl"
mkdir -p "$WORKTREE"
trap 'rm -rf "$TMP_DIR"' EXIT

# log() — capture _prl_log / try_direct_merge logging (defined before sourcing).
log() { printf '%s\n' "$*" >> "$TDM_LOG"; }

# forge_api stub: only the PR GET is hit (merged:false) — diagnostics never
# reach the API because ci_unsatisfied_required_contexts is stubbed below.
forge_api() {
  local path="$2"
  case "$path" in
    "/pulls/${PR_NUMBER}") printf '%s' "$PR_JSON" ;;
    *) printf 'null' ;;
  esac
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ci-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pr-lifecycle.sh"

# Deterministic diagnostics: no unsatisfied required contexts, so
# _PRL_MERGE_DETAIL stays empty and _PR_MERGE_ERROR is byte-for-byte what it
# was before #2158.
ci_unsatisfied_required_contexts() { return 0; }

# ── 1 + 2. _PR_MERGE_WALLED in pr_merge ──────────────────────────────────────
# The curl stub mirrors `curl -s -w "\n%{http_code}"` output: body, newline, 405.
MERGE_BODY="$WALL_BODY"
curl() { printf '%s\n405\n' "$MERGE_BODY"; }

ac_log "AC1: pr_merge with the wall's 405 sets _PR_MERGE_WALLED=1"
rc=0
pr_merge "$PR_NUMBER" || rc=$?
ac_assert_eq "$rc" "2" "pr_merge must return 2 on HTTP 405, got $rc"
ac_assert_eq "${_PR_MERGE_WALLED:-0}" "1" "the wall's 405 must set _PR_MERGE_WALLED=1"
ac_assert_eq "${_PR_MERGE_ERROR:-}" "blocked (HTTP 405): ${WALL_BODY}" \
  "the wall path must keep the exact _PR_MERGE_ERROR"

ac_log "AC2: pr_merge with a plain 405 sets _PR_MERGE_WALLED=0"
MERGE_BODY="$RETRY_BODY"
rc=0
pr_merge "$PR_NUMBER" || rc=$?
ac_assert_eq "$rc" "2" "pr_merge must return 2 on HTTP 405, got $rc"
ac_assert_eq "${_PR_MERGE_WALLED:-0}" "0" "a non-wall 405 must leave _PR_MERGE_WALLED=0"
ac_assert_eq "${_PR_MERGE_ERROR:-}" "blocked (HTTP 405): ${RETRY_BODY}" \
  "the non-wall path must keep the exact _PR_MERGE_ERROR"

# ── 3. walled 405 ends the walk, no rebase agent_run ─────────────────────────
ac_log "AC3: pr_walk_to_merge exits with reason walled and never calls agent_run"
out3=$(
  pr_poll_ci() { return 0; }
  pr_poll_review() { _PR_REVIEW_VERDICT="APPROVE"; return 0; }
  pr_merge() { _PR_MERGE_WALLED=1; _PR_MERGE_ERROR="blocked (HTTP 405): ${WALL_BODY}"; return 2; }
  agent_calls=0
  agent_run() { agent_calls=$((agent_calls + 1)); printf '%s\n' "$*" >> "$AGENT_CALLS"; return 0; }
  : > "$AGENT_CALLS"
  rc_inner=0
  pr_walk_to_merge "$PR_NUMBER" "sid" "$WORKTREE" || rc_inner=$?
  printf '%s\t%s\t%s\n' "$rc_inner" "${_PR_WALK_EXIT_REASON:-}" "$agent_calls"
)
rc3=$(printf '%s' "$out3" | cut -f1)
reason3=$(printf '%s' "$out3" | cut -f2)
calls3=$(printf '%s' "$out3" | cut -f3)
ac_assert_eq "$rc3" "1" "a walled walk must return 1, got $rc3"
ac_assert_eq "$reason3" "walled" "the walk must exit with _PR_WALK_EXIT_REASON=walled, got '$reason3'"
ac_assert_eq "$calls3" "0" "a walled walk must not run the rebase agent, got $calls3 calls"

# ── 4. a plain 405 still triggers the rebase agent ───────────────────────────
ac_log "AC4: a non-wall 405 still invokes the rebase agent_run"
out4=$(
  pr_poll_ci() { return 0; }
  pr_poll_review() { _PR_REVIEW_VERDICT="APPROVE"; return 0; }
  merge_calls=0
  pr_merge() {
    merge_calls=$((merge_calls + 1))
    if [ "$merge_calls" -eq 1 ]; then
      _PR_MERGE_WALLED=0
      _PR_MERGE_ERROR="blocked (HTTP 405): ${RETRY_BODY}"
      return 2
    fi
    return 0
  }
  agent_calls=0
  agent_run() { agent_calls=$((agent_calls + 1)); printf '%s\n' "$*" >> "$AGENT_CALLS"; return 0; }
  : > "$AGENT_CALLS"
  rc_inner=0
  pr_walk_to_merge "$PR_NUMBER" "sid" "$WORKTREE" || rc_inner=$?
  printf '%s\t%s\t%s\n' "$rc_inner" "${_PR_WALK_EXIT_REASON:-}" "$agent_calls"
)
rc4=$(printf '%s' "$out4" | cut -f1)
reason4=$(printf '%s' "$out4" | cut -f2)
agent_calls4=$(printf '%s' "$out4" | cut -f3)
ac_assert_eq "$rc4" "0" "the walk must reach the merge after the rebase, got $rc4"
ac_assert_eq "$reason4" "merged" "the walk must end merged, got '$reason4'"
ac_assert_eq "$agent_calls4" "1" "the non-wall 405 must invoke the rebase agent exactly once, got $agent_calls4 calls"
grep -qF 'approved but merge failed' "$AGENT_CALLS" \
  || ac_fail "the rebase prompt must contain 'approved but merge failed', got: $(cat "$AGENT_CALLS")"

# ── 5. try_direct_merge: walled → 2, no block state, no escalation ───────────
ac_log "AC5: try_direct_merge returns 2 on a walled merge without escalating"
FN_TDM="$(ac_extract_fn try_direct_merge "$POLL")"
[ -n "$FN_TDM" ] || ac_fail "try_direct_merge() is not defined in dev/dev-poll.sh"
# shellcheck disable=SC2086
eval "$FN_TDM"

# curl stub records every invocation; on the walled path none should happen.
curl() { printf '%s\n' "$*" >> "$TDM_CURL"; printf 'null'; }
: > "$TDM_CURL"
: > "$TDM_RECORDS"
: > "$TDM_LOG"

pr_merge_block_escalated() { return 1; }
pr_merge() {
  _PR_MERGE_WALLED=1
  _PR_MERGE_HEAD_SHA="$HEAD_SHA"
  _PR_MERGE_ERROR="blocked (HTTP 405): ${WALL_BODY}"
  return 2
}
pr_merge_block_record() { printf '%s\n' "$*" >> "$TDM_RECORDS"; printf 'retry'; }
issue_close() { printf 'issue_close\n' >> "$TDM_RECORDS"; }
mirror_push() { :; }
ci_fix_tracker_reset() { :; }
_ilc_in_progress_id() { printf '0'; }

rc=0
try_direct_merge "$PR_NUMBER" "$ISSUE_NUMBER" "$HEAD_SHA" || rc=$?
ac_assert_eq "$rc" "2" "try_direct_merge must return 2 for a walled merge, got $rc"
state_file=$(pr_merge_block_state "$PR_NUMBER")
if [ -e "$state_file" ]; then
  ac_fail "a walled merge must not create the merge-block state file $state_file"
fi
if [ -s "$TDM_RECORDS" ]; then
  ac_fail "try_direct_merge must not call pr_merge_block_record for a walled merge: $(cat "$TDM_RECORDS")"
fi
if grep -q "/issues/${ISSUE_NUMBER}/comments" "$TDM_CURL"; then
  ac_fail "try_direct_merge must not post an escalation comment for a walled merge"
fi
if grep -q "/issues/${ISSUE_NUMBER}/labels" "$TDM_CURL"; then
  ac_fail "try_direct_merge must not add the blocked label for a walled merge"
fi
grep -qF 'waits for the owner' "$TDM_LOG" \
  || ac_fail "try_direct_merge must log that a walled PR waits for the owner (#2158)"

# ── 6. dev-agent.sh wiring: walled before the terminal/block path ────────────
ac_log "AC6: dev-agent.sh handles walled before dev_walk_reason_terminal/issue_block"
walled_line=$(grep -nF '"walled"' "$AGENT" | head -n1 | cut -d: -f1)
owner_line=$(grep -nF 'outcome="waiting_owner"' "$AGENT" | head -n1 | cut -d: -f1)
block_line=$(grep -nF 'issue_block "$ISSUE" "${_PR_WALK_EXIT_REASON:-agent_failed}"' "$AGENT" | head -n1 | cut -d: -f1)
[ -n "$walled_line" ] || ac_fail "dev-agent.sh must check _PR_WALK_EXIT_REASON == walled"
[ -n "$owner_line" ] || ac_fail "the walled branch must set outcome=\"waiting_owner\""
[ -n "$block_line" ] || ac_fail "the terminal walk-failure branch must still call issue_block"
if [ "$walled_line" -ge "$owner_line" ] || [ "$owner_line" -ge "$block_line" ]; then
  ac_fail "the walled branch (line $walled_line, outcome line $owner_line) must come before issue_block (line $block_line)"
fi

# ── 7. documentation + syntax ────────────────────────────────────────────────
grep -qF 'unexpected_verdict | walled' "$LIFECYCLE" \
  || ac_fail "the _PR_WALK_EXIT_REASON globals list must include walled"
grep -qF 'unexpected_verdict, walled)' "$LIFECYCLE" \
  || ac_fail "the pr_walk_to_merge header must list walled as an exit reason"
grep -qF '_PR_MERGE_WALLED' "$LIFECYCLE" \
  || ac_fail "pr_merge must document/set _PR_MERGE_WALLED"
grep -qF 'Changed protected files' "$LIFECYCLE" \
  || ac_fail "pr_merge must detect the wall's 'Changed protected files' reason"
grep -qF 'walled (the owner merges)' "$POLL" \
  || ac_fail "try_direct_merge's Returns line must document the walled case"
grep -qF 'only `disinto-admin` can merge it. Such a 405 sets `_PR_MERGE_WALLED`' "$REPO_ROOT/dev/AGENTS.md" \
  || ac_fail "dev/AGENTS.md must document the walled handling (#2158)"

for f in "$LIFECYCLE" "$AGENT" "$POLL"; do
  bash -n "$f" || ac_fail "bash -n fails on $f"
done
if command -v shellcheck >/dev/null 2>&1; then
  # CI (.woodpecker/shellcheck-scope.sh) lints with --severity=warning.
  shellcheck --severity=warning "$LIFECYCLE" "$AGENT" "$POLL" \
    || ac_fail "shellcheck must be clean on lib/pr-lifecycle.sh dev/dev-agent.sh dev/dev-poll.sh"
fi

ac_pass
