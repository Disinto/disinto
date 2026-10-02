#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1677.sh
#
# Issue #1677: an attempt stopped by a resource limit hands its work to the
# next attempt.
#
# Problem: when a dev attempt exits without a push (e.g. the wall-clock
# timeout rc=124), dev-agent.sh re-queued the issue and then deleted the
# worktree and session — so the next attempt restarted from scratch. Observed
# on #1620 (4 x 2 h attempts, 3 wrote no file at all).
#
# Fix: on a resource-limit requeue (timeout, error_max_turns, no_result) the
# no-push path commits any uncommitted work as a local "wip" commit and writes
# the branch to a carry file; it keeps the worktree + session so the next run
# resumes. The worktree-setup section calls dev_carry_restore and, when it
# finds a matching worktree on the named branch, adopts that branch and skips
# the fresh attempt-branch naming / worktree_create (CARRY_MODE=true), building
# the CRASH-RECOVERY-style prompt. Every other exit (merge, refusal, block)
# cleans up as before and removes the carry file.
#
# Self-contained: temp git repos, no network. The decision functions are
# extracted from dev/dev-agent.sh with ac_extract_fn() + eval; the mutating
# API is stubbed in-process (tests/lib/acceptance-no-push-harness.sh).
#
# Acceptance criteria exercised here:
#   1. carry_save with an uncommitted file -> one new local commit + the carry
#      file names the branch + no push to a (real) bare remote.
#   2. carry_save with a clean worktree -> no new commit, carry file still
#      written.
#   3. carry_restore with a matching worktree -> prints the branch, rc 0.
#   4. carry_restore with a missing worktree -> rc 1 + the carry file removed.
#   5. no_push_outcome rc 124 + attempt 0 -> DEV_CARRY=1 (requeue).
#   6. no_push_outcome attempt 2 (block) -> DEV_CARRY=0.
#   7. bash tests/acceptance/issue-1677.sh exits 0 and ac_pass is called.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
source "$REPO_ROOT/tests/lib/acceptance-no-push-harness.sh"

ac_require_cmd git
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

# The extracted dev_carry_save()/dev_carry_restore()/no_push_outcome() call
# log() and read the ISSUE/BRANCH globals; provide a silent stand-in and the
# globals as dev-agent.sh would have them.
# shellcheck disable=SC2317
log() { :; }

ISSUE=1677
BRANCH="fix/issue-${ISSUE}"
NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"
CARRY_BRANCH="fix/issue-1677-1"

# Globals the extracted functions reference (mirrors dev-agent.sh).
DEV_CARRY=0

# ── Extract the three decision functions from dev-agent.sh ──────────────────
ac_load_decision_fn "$TARGET" dev_carry_save
ac_load_decision_fn "$TARGET" dev_carry_restore
ac_load_decision_fn "$TARGET" no_push_outcome

# ── 1/2: dev_carry_save ──────────────────────────────────────────────────────
# A bare local repo with one base commit, a branch, and an uncommitted file.
REPO="$TMP_DIR/repo"
REMOTE="$TMP_DIR/remote.git"
rm -rf "$REPO" "$REMOTE"
git init -q "$REPO"
git -C "$REPO" config user.email "ac@example.com"
git -C "$REPO" config user.name "ac"
git -C "$REPO" commit --allow-empty -m "base" -q
# A bare remote mirroring the base commit (taken before the wip commit).
git clone --bare "$REPO" "$REMOTE" -q
git -C "$REPO" checkout -q -b "$CARRY_BRANCH"
printf 'feature\n' > "$REPO/feature.txt"

count_commits() { git -C "$1" rev-list --count HEAD 2>/dev/null | tr -d '[:space:]'; }
remote_commits() { git -C "$1" rev-list --count --all 2>/dev/null | tr -d '[:space:]'; }

# 1. carry_save with an uncommitted file.
CARRY_FILE="$TMP_DIR/carry1"
dev_carry_save "$REPO" "$CARRY_BRANCH"
# One new local commit...
[ "$(count_commits "$REPO")" -eq 2 ] || ac_fail "carry_save: expected 2 commits (base + wip), got $(count_commits "$REPO")"
# ...with the exact wip message...
[ "$(git -C "$REPO" log -1 --format=%B 2>/dev/null)" = "wip(#${ISSUE}): attempt stopped by a resource limit" ] \
  || ac_fail "carry_save: wip commit message is: $(git -C "$REPO" log -1 --format=%B 2>/dev/null)"
# ...the uncommitted file was folded into the commit (worktree now clean)...
[ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] \
  || ac_fail "carry_save: worktree not clean after committing the wip work"
git -C "$REPO" rev-parse --verify "HEAD:feature.txt" >/dev/null 2>&1 \
  || ac_fail "carry_save: wip commit did not include the uncommitted file (feature.txt)"
# ...the carry file names the branch...
[ "$(cat "$CARRY_FILE")" = "$CARRY_BRANCH" ] \
  || ac_fail "carry_save: carry file is: $(cat "$CARRY_FILE") (expected ${CARRY_BRANCH})"
# ...and nothing was pushed to the bare remote (still just the base commit).
base_remote=$(remote_commits "$REMOTE")
[ "$base_remote" -eq 1 ] || ac_fail "carry_save: remote has $(remote_commits "$REMOTE") commits (expected 1 base)"
wip_sha="$(git -C "$REPO" rev-parse HEAD)"
if git -C "$REMOTE" cat-file -e "$wip_sha" 2>/dev/null; then
  ac_fail "carry_save: pushed the wip commit to the remote (it must be local-only)"
fi

# 2. carry_save with a clean worktree -> no new commit, carry file still written.
# The repo is clean now (wip committed in test 1).
pre_count=$(count_commits "$REPO")
dev_carry_save "$REPO" "$CARRY_BRANCH"
[ "$(count_commits "$REPO")" -eq "$pre_count" ] \
  || ac_fail "carry_save(clean): committed when clean (expected ${pre_count}, got $(count_commits "$REPO"))"
[ -f "$CARRY_FILE" ] && [ "$(cat "$CARRY_FILE")" = "$CARRY_BRANCH" ] \
  || ac_fail "carry_save(clean): carry file missing or wrong after clean worktree"

# ── 3/4: dev_carry_restore ───────────────────────────────────────────────────
# 3. Matching worktree (repo is on CARRY_BRANCH, carry1 names CARRY_BRANCH).
restore_rc=0
restore_out="$(dev_carry_restore "$REPO")" || restore_rc=$?
[ "$restore_rc" -eq 0 ] && [ "$restore_out" = "$CARRY_BRANCH" ] \
  || ac_fail "carry_restore(matching): got rc $restore_rc / output: ${restore_out:-(empty)} (expected ${CARRY_BRANCH})"

# 4. Missing worktree -> rc 1 and the carry file removed.
rm -f "$CARRY_FILE"
printf '%s' "$CARRY_BRANCH" > "$CARRY_FILE"   # re-establish a valid carry file
if dev_carry_restore "$TMP_DIR/does-not-exist"; then
  ac_fail "carry_restore(missing): expected rc 1, got 0"
fi
if [ -f "$CARRY_FILE" ]; then
  ac_fail "carry_restore(missing): did not remove the carry file"
fi

# ── 5/6: no_push_outcome DEV_CARRY ───────────────────────────────────────────
# The harness stubs issue_block()/issue_requeue(); the ac_assert_* helpers re-run
# no_push_outcome() with the $ISSUE/$NO_PUSH_TEXT globals and assert which fired.
# DEV_CARRY is set by the extracted no_push_outcome() itself, so it is read after
# each decision call.
ac_no_push_stub
# A diag row whose subtype is a resource limit (rc 124 overrides it).
printf '{"type":"result","subtype":"error_max_turns"}\n' > "$TMP_DIR/diag.json"

# 5. rc 124 + attempt 0 (first attempt) -> requeue + DEV_CARRY=1.
ac_assert_requeue "$TMP_DIR/diag.json" 124 0 "timeout" "rc124 attempt0 requeues"
[ "${DEV_CARRY:-}" = "1" ] \
  || ac_fail "rc124 attempt0: expected DEV_CARRY=1, got ${DEV_CARRY:-uninit}"

# rc 124 (wall-clock timeout) is the more recent event than a present
# error_max_turns row, so it must be reported as "timeout".
CALLS=()
no_push_outcome "$ISSUE" "$TMP_DIR/diag.json" 124 0 "$NO_PUSH_TEXT"
ac_has_call_matching "issue_requeue ${ISSUE} timeout " \
  || ac_fail "rc124 + error_max_turns row: must report 'timeout', got: ${CALLS[*]:-nothing}"
if ac_has_call_matching "issue_requeue ${ISSUE} error_max_turns "; then
  ac_fail "rc124 must be reported as 'timeout', not 'error_max_turns'"
fi

# 6. attempt 2 (third attempt) with a resource limit -> block + DEV_CARRY=0.
ac_assert_block_reason "$TMP_DIR/diag.json" 124 2 "no_push_after_3_attempts" "attempt2 blocks"
[ "${DEV_CARRY:-}" = "0" ] \
  || ac_fail "attempt2: expected DEV_CARRY=0, got ${DEV_CARRY:-uninit}"

ac_pass
