#!/usr/bin/env bash
# dev-agent.sh — Synchronous developer agent for a single issue
#
# Usage: ./dev-agent.sh <issue-number>
#
# Architecture:
#   Synchronous bash loop using claude -p (one-shot invocations).
#   Session continuity via --resume and .sid file.
#   CI/review loop delegated to pr_walk_to_merge().
#
# Flow:
#   1. Preflight: issue_check_deps, issue_claim, memory guard, lock
#   2. Worktree: worktree_recover or worktree_create
#   3. Prompt: build context (issue body, open issues, push instructions)
#   4. Implement: agent_run → Claude implements + pushes → save session_id
#   5. Create PR: pr_create or pr_find_by_branch
#   6. Walk to merge: pr_walk_to_merge (CI fix, review feedback loops)
#   7. Cleanup: worktree_cleanup, issue_close, label cleanup
#
# Session file: /tmp/dev-session-{project}-{issue}.sid
# Log:          tail -f dev-agent.log

set -euo pipefail

# Load shared environment and libraries
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
source "$(dirname "$0")/../lib/issue-lifecycle.sh"
source "$(dirname "$0")/../lib/worktree.sh"
source "$(dirname "$0")/../lib/pr-lifecycle.sh"
# #1688: review text for a restarted attempt's recovery prompt
source "$(dirname "$0")/../lib/pr-review-feedback.sh"
source "$(dirname "$0")/../lib/mirrors.sh"
source "$(dirname "$0")/../lib/agent-sdk.sh"
source "$(dirname "$0")/../lib/formula-session.sh"
source "$(dirname "$0")/../lib/tape.sh"
# #1608: reason -> signature lookup, shared with dev-poll.sh (#1609)
source "$(dirname "$0")/../lib/signature.sh"

# Auto-pull factory code to pick up merged fixes before any logic runs
git -C "$FACTORY_ROOT" pull --ff-only origin main 2>/dev/null || true

# --- Config ---
ISSUE="${1:?Usage: dev-agent.sh <issue-number>}"
REPO_ROOT="${PROJECT_REPO_ROOT}"

LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-default}.lock"
STATUSFILE="/tmp/dev-agent-status-${PROJECT_NAME:-default}"
BRANCH="fix/issue-${ISSUE}"  # Default; will be updated after FORGE_REMOTE is known
WORKTREE="/tmp/${PROJECT_NAME}-worktree-${ISSUE}"
SID_FILE="/tmp/dev-session-${PROJECT_NAME}-${ISSUE}.sid"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
IMPL_SUMMARY_FILE="/tmp/dev-impl-summary-${PROJECT_NAME}-${ISSUE}.txt"
# claude_run_with_watchdog records the claude process-group ID here so any
# exit path (release, crash, signal) can kill leftover claude (#1070).
CLAUDE_PGID_FILE="/tmp/dev-claude-pgid-${PROJECT_NAME:-default}-${ISSUE}"
# #1677: carry-over when an attempt is stopped by a resource limit.
# DEV_CARRY is set by no_push_outcome() to 1 when the run is re-queued for a
# resource limit (work should be handed to the next attempt) and 0 on every
# other path (including all blocking paths). CARRY_FILE records which branch
# the carried work lives on.
CARRY_FILE="/tmp/dev-carry-${PROJECT_NAME:-default}-${ISSUE}"
DEV_CARRY=0

LOGFILE="${DISINTO_LOG_DIR}/dev/dev-agent.log"

log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

# Record what this run actually resolved (#1070). WORKTREE and IMPL_SUMMARY_FILE
# come from PROJECT_NAME; the issue and the prompt come from FORGE_REPO. A run
# was observed where those two named different projects.
log "context: PROJECT_TOML=${PROJECT_TOML:-(unset)} PROJECT_NAME=${PROJECT_NAME:-(unset)} FORGE_REPO=${FORGE_REPO:-(unset)} REPO_ROOT=${REPO_ROOT:-(unset)} WORKTREE=${WORKTREE}"

status() {
  printf '[%s] dev-agent #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" > "$STATUSFILE"
  log "$*"
}

# =============================================================================
# CARRY OVER (#1677)
# =============================================================================
# When an attempt is stopped by a resource limit (no push) its uncommitted
# work is carried to the next attempt instead of being thrown away. CARRY_FILE
# records which branch the carried work lives on; the worktree and session are
# kept across the requeue so the next run can resume where the last left off.

# dev_carry_restore WORKTREE
# If a carry file exists and WORKTREE is a git worktree on the branch it names,
# echo that branch and return 0 (the caller adopts it and skips worktree_create).
# Otherwise the carry is stale (missing/empty file, or worktree absent or off the
# branch): remove the carry file and return 1.
dev_carry_restore() {
  local wt="$1"
  local br current
  br="$(cat "$CARRY_FILE" 2>/dev/null)" || br=""
  if [ -n "$br" ]; then
    current="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || current=""
    if [ "$current" = "$br" ]; then
      printf '%s' "$br"
      return 0
    fi
  fi
  rm -f "$CARRY_FILE"
  return 1
}

# dev_carry_save WORKTREE BRANCH
# Commit any uncommitted work in WORKTREE as a local "wip" commit (never pushed)
# so the next attempt can resume, and record BRANCH in CARRY_FILE so a following
# run knows what to adopt. A clean worktree still gets the carry file (nothing to
# commit, but the branch is recorded for resume).
dev_carry_save() {
  local wt="$1" br="$2"
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    log "dev_carry_save: committing uncommitted work in ${wt}"
    git -C "$wt" add -A || log "WARNING: dev_carry_save: git add -A failed in ${wt}"
    git -C "$wt" commit -m "wip(#${ISSUE}): attempt stopped by a resource limit" \
      || log "WARNING: dev_carry_save: git commit failed in ${wt}"
  else
    log "dev_carry_save: worktree ${wt} is clean; nothing to commit"
  fi
  printf '%s' "$br" > "$CARRY_FILE"
  log "dev_carry_save: recorded branch ${br} in ${CARRY_FILE}"
}

# =============================================================================
# CLEANUP
# =============================================================================
CLAIMED=false
PR_NUMBER=""
# #1532: PR_WALK_RC is 0 only when pr_walk_to_merge() returned 0 (merged); 1 for
# every other exit. close_dev_tape_outcome() records merged/ci_green from this
# flag, never from the process exit code. One outcome per process.
PR_WALK_RC=1
_DEV_TAPE_OUTCOME_WRITTEN=0
# #1608: the recorded refusal status (set by handle_refusal) so the exit
# trap can tell a disposition refusal from a failure walk. One per process.
_DEV_REFUSAL_STATUS=""

# kill_stale_claude — kill any claude process group left behind by
# claude_run_with_watchdog (#1070: a session was observed outliving its
# watchdog and holding a llama slot until a manual pkill). The watchdog
# removes the pgid file once the group is dead, so a present file means
# claude is still running (or a kill is in flight).
kill_stale_claude() {
  [ -f "$CLAUDE_PGID_FILE" ] || return 0
  local pgid
  pgid=$(head -n1 "$CLAUDE_PGID_FILE" 2>/dev/null) || return 0
  [ -n "$pgid" ] || return 0
  if kill -0 "$pgid" 2>/dev/null; then
    log "cleanup: killing leftover claude process group ${pgid}"
    kill -TERM -- "-$pgid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pgid" 2>/dev/null; then
      log "cleanup: SIGKILL leftover claude process group ${pgid}"
      kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
  fi
  rm -f "$CLAUDE_PGID_FILE"
}

cleanup() {
  kill_stale_claude
  rm -f "$LOCKFILE" "$STATUSFILE"
  # If we claimed the issue but never created a PR, release it
  if [ "$CLAIMED" = true ] && [ -z "$PR_NUMBER" ]; then
    log "cleanup: releasing issue (no PR created)"
    issue_release "$ISSUE"
  fi
}

# close_dev_tape_outcome — append the terminal outcome for the picked proposal
# (#1532: close the dev tape pair).
#
# dev-poll.sh emits an outcome only when it itself merges or abandons a PR
# (the direct-merge scan and stale-branch abandonment). dev-agent.sh merges
# via pr_walk_to_merge() and returns, so without this the outcome would never
# land: Forge closes the issue and the next poll sees no open PR, writing nothing.
# This runs from the EXIT trap on every terminal path (merge, no-push refusal,
# block, signal, crash) and appends at most one outcome for the picked proposal.
#
#   * bits.merged / bits.ci_green are 1 only when pr_walk_to_merge() returned 0
#     (PR_WALK_RC); every other exit records 0/0. Never inferred from the process
#     exit code.
#   * numbers.ci_red = ${PR_WALK_CI_RED:-0} (every CI failure the walk
#     observed, 0 when no walk ran) and numbers.review_rounds =
#     ${PR_WALK_REVIEW_ROUNDS:-0} (#1616).
#   * numbers.duration_s = now - started (clamped >= 0) when the started epoch
#     file /tmp/dev-proposal-started-<project>-<issue> is present and an integer
#     epoch; omitted (never 0) otherwise.
#   * children = {}, payloads = [].
#
# No id file (missing or empty) -> write nothing (return 0). The id and started
# files are never deleted. Always returns 0; a tape failure only logs a WARNING
# and never changes the exit code.
close_dev_tape_outcome() {
  if [ "${_DEV_TAPE_OUTCOME_WRITTEN:-0}" = 1 ]; then
    return 0
  fi
  # #1705: a walk that ended in ci_timeout is not a terminal outcome — the
  # PR is still open and dev-poll owns it (it merges, fixes or waits on it
  # later, and emits the outcome there). No tape record from dev-agent.sh.
  if [ "${PR_WALK_RC:-0}" != 0 ] && ! dev_walk_reason_terminal "${_PR_WALK_EXIT_REASON:-}"; then
    return 0
  fi

  # Initialised to safe defaults: the function must be set -u safe (it is
  # sourced-run in subshells by the acceptance tests and by dev-poll traps).
  local id_file="" id="" bits="" numbers="" merged=0
  local duration_s="" has_duration=0 reason="" signature=""

  id_file="/tmp/dev-proposal-id-${PROJECT_NAME:-default}-${ISSUE}"
  id="$(cat "$id_file" 2>/dev/null)" || id=""
  if [ -z "$id" ]; then
    return 0
  fi

  # merged/ci_green come from the walk result, not the process exit code.
  # #1608: classify the exit so the record distinguishes a disposition
  # refusal, a failure walk and a merge, and carries a reason for the rubric
  # signature (loop "dev").
  #   * A recorded disposition refusal (_DEV_REFUSAL_STATUS, set by
  #     handle_refusal for too_large/already_done/needs_ops/design_conflict)
  #     writes rejected: 1 with reason = the status.
  #   * A failure walk (PR_WALK_RC != 0, no recorded refusal) keeps today's
  #     bits and uses _PR_WALK_EXIT_REASON as the reason (possibly empty).
  #   * A merged walk keeps today's bits, no reason.
  #   * unmet_dependency is never recorded (it blocks the issue instead of
  #     re-queueing it, #1672), so it falls through to the failure-walk
  #     shape: no rejected bit.
  if [ -n "${_DEV_REFUSAL_STATUS:-}" ]; then
    merged=0
    reason="${_DEV_REFUSAL_STATUS}"
    bits="$(jq -cn '{merged: 0, ci_green: 0, rejected: 1}' 2>/dev/null)" || bits=""
  elif [ "$PR_WALK_RC" -eq 0 ]; then
    merged=1
    reason=""
    bits="$(jq -cn --argjson m "$merged" '{merged: $m, ci_green: $m}' 2>/dev/null)" || bits=""
  else
    merged=0
    reason="${_PR_WALK_EXIT_REASON:-}"
    bits="$(jq -cn --argjson m "$merged" '{merged: $m, ci_green: $m}' 2>/dev/null)" || bits=""
  fi
  if [ -z "$bits" ]; then
    log "WARNING: tape: could not build outcome bits for #${ISSUE}"
    return 0
  fi

  # duration_s (#1532): pick->terminal span via proposal_elapsed_s (#1452);
  # omitted (never 0) when the started file is missing or not an integer epoch.
  has_duration=0
  if duration_s="$(proposal_elapsed_s "$ISSUE")"; then
    has_duration=1
  fi

  # Walk totals (#1616): PR_WALK_CI_RED / PR_WALK_REVIEW_ROUNDS are set by
  # pr_walk_to_merge() when it ran; the ${...:-0} defaults yield 0 on the
  # no-walk (early-exit) paths. duration_s logic is unchanged.
  if [ "$has_duration" = 1 ]; then
    numbers="$(jq -cn --argjson ci_red "${PR_WALK_CI_RED:-0}" \
      --argjson review_rounds "${PR_WALK_REVIEW_ROUNDS:-0}" \
      --argjson d "$duration_s" \
      '{ci_red: $ci_red, review_rounds: $review_rounds, duration_s: $d}' 2>/dev/null)" || numbers=""
  else
    numbers="$(jq -cn --argjson ci_red "${PR_WALK_CI_RED:-0}" \
      --argjson review_rounds "${PR_WALK_REVIEW_ROUNDS:-0}" \
      '{ci_red: $ci_red, review_rounds: $review_rounds}' 2>/dev/null)" || numbers=""
  fi
  if [ -z "$numbers" ]; then
    log "WARNING: tape: could not build outcome numbers for #${ISSUE}"
    return 0
  fi

  # Claim the write so a second invocation in the same process appends nothing.
  _DEV_TAPE_OUTCOME_WRITTEN=1

  # #1608: resolve the reason to a rubric signature (loop "dev", lib/
  # signature.sh) and, when the result is non-empty, pass it to tape_outcome
  # as the 6th arg (the record's "signature" field). An unknown reason (empty
  # resolution) leaves the record in its pre-#1608 shape (no signature). A
  # lookup never changes the exit code and never skips the write.
  if [ -n "$reason" ]; then
    signature="$(signature_for "$reason" dev)" || signature=""
  fi
  local rc=0
  if [ -n "$signature" ]; then
    rc=0
    tape_outcome "$id" "$bits" "$numbers" '{}' '[]' "$signature" >/dev/null 2>&1 || rc=1
  else
    rc=0
    tape_outcome "$id" "$bits" "$numbers" '{}' '[]' >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    log "WARNING: tape: failed to append outcome record ${id} for #${ISSUE}"
    return 0
  fi

  if [ "$has_duration" = 1 ]; then
    log "tape: recorded dev outcome for #${ISSUE} (merged: ${merged}, duration_s: ${duration_s})"
  else
    log "tape: recorded dev outcome for #${ISSUE} (merged: ${merged})"
  fi
  return 0
}
# Route HUP/INT/TERM through exit so the EXIT trap (cleanup +
# close_dev_tape_outcome) always runs, including on signal death — otherwise
# a signalled dev-agent leaves its claude child running (#1070) and the dev
# tape pair stays open (#1532). The trap captures the original exit status and
# restores it: every command in the body is guarded so set -e cannot abort
# mid-trap, and close_dev_tape_outcome() always returns 0, so a tape failure
# logs a WARNING without changing the exit code.
# dev_walk_reason_terminal REASON — return 1 iff REASON is ci_timeout
# (#1705: a walk that ran out of CI-wait time did not fail; the PR is still
# open and dev-poll owns it). Any other reason (ci_exhausted,
# review_exhausted, merge_blocked, closed_externally, ... and the empty
# default) is a real failure and returns 0.
dev_walk_reason_terminal() {
  case "$1" in
    ci_timeout) return 1 ;;
    *) return 0 ;;
  esac
}
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck disable=SC2154  # _trap_rc is assigned inside the trap string
trap '_trap_rc=$?; cleanup || true; close_dev_tape_outcome || true; exit $_trap_rc' EXIT
# Note: no rm of $CLAUDE_PGID_FILE at startup — a stale file from a crashed
# prior run points at the leaked claude group, and cleanup() will kill it
# (self-healing). claude_run_with_watchdog overwrites the file each run.

# =============================================================================
# LOG ROTATION
# =============================================================================
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
  log "Log rotated"
fi

# =============================================================================
# MEMORY GUARD
# =============================================================================
memory_guard 2000

# =============================================================================
# CONCURRENCY LOCK
# =============================================================================
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "SKIP: another dev-agent running (PID ${LOCK_PID})"
    exit 0
  fi
  log "Removing stale lock (PID ${LOCK_PID:-?})"
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# =============================================================================
# FETCH ISSUE
# =============================================================================
status "fetching issue"
ISSUE_JSON=$(forge_api GET "/issues/${ISSUE}") || true
if [ -z "$ISSUE_JSON" ] || ! printf '%s' "$ISSUE_JSON" | jq -e '.id' >/dev/null 2>&1; then
  log "ERROR: failed to fetch issue #${ISSUE} (API down or invalid response)"; exit 1
fi
ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_BODY_ORIGINAL="$ISSUE_BODY"
ISSUE_STATE=$(printf '%s' "$ISSUE_JSON" | jq -r '.state')

if [ "$ISSUE_STATE" != "open" ]; then
  log "SKIP: issue #${ISSUE} is ${ISSUE_STATE}"
  echo '{"status":"already_done","reason":"issue is closed"}' > "$PREFLIGHT_RESULT"
  exit 0
fi

log "Issue: ${ISSUE_TITLE}"

# =============================================================================
# GUARD: Reject formula-labeled issues
# =============================================================================
ISSUE_LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")') || true
if printf '%s' "$ISSUE_LABELS" | grep -qw 'formula'; then
  log "SKIP: issue #${ISSUE} has 'formula' label"
  echo '{"status":"unmet_dependency","blocked_by":"formula dispatch not implemented","suggestion":null}' > "$PREFLIGHT_RESULT"
  exit 0
fi

# --- Append human comments to issue body ---
_bot_login=$(forge_whoami)
_bot_logins="${_bot_login}"
[ -n "${FORGE_BOT_USERNAMES:-}" ] && \
  _bot_logins="${_bot_logins:+${_bot_logins},}${FORGE_BOT_USERNAMES}"

ISSUE_COMMENTS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues/${ISSUE}/comments" | \
  jq -r --arg bots "$_bot_logins" \
    '($bots | split(",") | map(select(. != ""))) as $bl |
     .[] | select(.user.login as $u | $bl | index($u) | not) |
     "### @\(.user.login) (\(.created_at[:10])):\n\(.body)\n"' 2>/dev/null || true)
if [ -n "$ISSUE_COMMENTS" ]; then
  ISSUE_BODY="${ISSUE_BODY}

## Issue comments
${ISSUE_COMMENTS}"
fi

# =============================================================================
# PREFLIGHT: Check dependencies
# =============================================================================
status "preflight check"

if ! issue_check_deps "$ISSUE"; then
  BLOCKED_LIST=$(printf '#%s, ' "${_ISSUE_BLOCKED_BY[@]}" | sed 's/, $//')
  COMMENT_BODY="### Blocked by open issues

This issue depends on ${BLOCKED_LIST}, which $([ "${#_ISSUE_BLOCKED_BY[@]}" -eq 1 ] && echo "is" || echo "are") not yet closed."
  [ -n "$_ISSUE_SUGGESTION" ] && COMMENT_BODY="${COMMENT_BODY}

**Suggestion:** Work on #${_ISSUE_SUGGESTION} first."

  issue_post_refusal "$ISSUE" "🚧" "Unmet dependency" "$COMMENT_BODY"

  # Write preflight result
  BLOCKED_JSON=$(printf '%s\n' "${_ISSUE_BLOCKED_BY[@]}" | jq -R 'tonumber' | jq -sc '.')
  if [ -n "$_ISSUE_SUGGESTION" ]; then
    jq -n --argjson blocked "$BLOCKED_JSON" --argjson suggestion "$_ISSUE_SUGGESTION" \
      '{"status":"unmet_dependency","blocked_by":$blocked,"suggestion":$suggestion}' > "$PREFLIGHT_RESULT"
  else
    jq -n --argjson blocked "$BLOCKED_JSON" \
      '{"status":"unmet_dependency","blocked_by":$blocked,"suggestion":null}' > "$PREFLIGHT_RESULT"
  fi
  log "BLOCKED: unmet dependencies: ${_ISSUE_BLOCKED_BY[*]}"
  exit 0
fi

log "preflight passed"

# =============================================================================
# CLAIM ISSUE
# =============================================================================
if ! issue_claim "$ISSUE"; then
  log "SKIP: failed to claim issue #${ISSUE} (already assigned to another agent)"
  echo '{"status":"already_done","reason":"issue was claimed by another agent"}' > "$PREFLIGHT_RESULT"
  exit 0
fi
CLAIMED=true

# =============================================================================
# CHECK FOR EXISTING PR (recovery mode)
# =============================================================================
RECOVERY_MODE=false
PRIOR_ART_DIFF=""
# #1677: true only when a carried worktree (from a re-queued resource-limit
# attempt) was adopted at worktree setup.
CARRY_MODE=false

if pr_find_for_issue "$ISSUE" "$ISSUE_BODY_ORIGINAL" "$BRANCH"; then
  case "$_PR_FOUND_MODE" in
    open)
      PR_NUMBER="$_PR_FOUND_NUMBER"
      BRANCH="$_PR_FOUND_BRANCH"
      RECOVERY_MODE=true
      log "found existing PR #${PR_NUMBER} on branch ${BRANCH}"
      ;;
    prior_art)
      PRIOR_ART_DIFF="$_PR_PRIOR_ART_DIFF"
      log "found closed PR #${_PR_FOUND_NUMBER} as prior art"
      ;;
  esac
fi

# Recover session_id from .sid file (crash recovery)
agent_recover_session

# =============================================================================
# WORKTREE SETUP
# =============================================================================
status "setting up worktree"
if ! cd "$REPO_ROOT"; then
  log "ERROR: REPO_ROOT=${REPO_ROOT} does not exist — cannot cd"
  log "Check PROJECT_REPO_ROOT vs compose PROJECT_NAME vs TOML name mismatch"
  exit 1
fi

# Determine forge remote by matching FORGE_URL host against git remotes
_forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
FORGE_REMOTE=$(git remote -v | awk -v host="$_forge_host" '$2 ~ host && /\(push\)/ {print $1; exit}')
FORGE_REMOTE="${FORGE_REMOTE:-origin}"
export FORGE_REMOTE
log "forge remote: ${FORGE_REMOTE}"

# Generate unique branch name per attempt to avoid collision with failed attempts
# Only apply when not in recovery mode (RECOVERY_MODE branch is already set from existing PR)
# First attempt: fix/issue-N, subsequent: fix/issue-N-1, fix/issue-N-2, etc.
if [ "$RECOVERY_MODE" = false ]; then
  # Count only branches matching fix/issue-N, fix/issue-N-1, fix/issue-N-2, etc. (exact prefix match)
  # Use explicit error handling to avoid silent failure from set -e + pipefail when git ls-remote fails.
  if _lr1=$(git ls-remote --heads "$FORGE_REMOTE" "refs/heads/fix/issue-${ISSUE}" 2>&1); then
    ATTEMPT=$(printf '%s\n' "$_lr1" | grep -c "refs/heads/fix/issue-${ISSUE}$" || true)
  else
    log "WARNING: git ls-remote failed for attempt counting: $_lr1"
    ATTEMPT=0
  fi
  ATTEMPT="${ATTEMPT:-0}"

  if _lr2=$(git ls-remote --heads "$FORGE_REMOTE" "refs/heads/fix/issue-${ISSUE}-*" 2>&1); then
    # Guard on empty to avoid off-by-one: command substitution strips trailing newlines,
    # so wc -l undercounts by 1 when output exists. Re-add newline only if non-empty.
    ATTEMPT=$((ATTEMPT + $( [ -z "$_lr2" ] && echo 0 || printf '%s\n' "$_lr2" | wc -l )))
  else
    log "WARNING: git ls-remote failed for suffix counting: $_lr2"
  fi
  if [ "$ATTEMPT" -gt 0 ]; then
    BRANCH="fix/issue-${ISSUE}-${ATTEMPT}"
  fi
fi
log "using branch: ${BRANCH}"

if [ "$RECOVERY_MODE" = true ]; then
  if ! worktree_recover "$WORKTREE" "$BRANCH" "$FORGE_REMOTE"; then
    log "ERROR: worktree recovery failed"
    issue_release "$ISSUE"
    CLAIMED=false
    exit 1
  fi
else
  # #1677: a re-queued attempt stopped by a resource limit may have carried its
  # work forward (dev_carry_save). If the worktree is a git worktree on the
  # branch the carry file names, adopt it and skip the fresh-branch naming and
  # worktree_create — the next run resumes from the saved state.
  carry_branch=""
  if carry_branch="$(dev_carry_restore "$WORKTREE")"; then
    CARRY_MODE=true
    BRANCH="$carry_branch"
    log "carry: adopting carried work on branch ${BRANCH}"
  else
    # Fresh attempt: ensure a clean repo state, count existing attempt branches,
    # and create a worktree on the named branch.
    if [ -d "$REPO_ROOT/.git/rebase-merge" ] || [ -d "$REPO_ROOT/.git/rebase-apply" ]; then
      log "WARNING: stale rebase detected — aborting"
      git rebase --abort 2>/dev/null || true
    fi
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT_BRANCH" != "${PRIMARY_BRANCH}" ]; then
      git checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
    fi

    git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null
    git pull --ff-only "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
    if ! worktree_create "$WORKTREE" "$BRANCH" "${FORGE_REMOTE}/${PRIMARY_BRANCH}"; then
      log "ERROR: worktree creation failed"
      issue_release "$ISSUE"
      CLAIMED=false
      exit 1
    fi

    # Symlink shared node_modules from main repo
    for lib_dir in "$REPO_ROOT"/onchain/lib/*/; do
      lib_name=$(basename "$lib_dir")
      if [ -d "$lib_dir/node_modules" ] && [ ! -d "$WORKTREE/onchain/lib/$lib_name/node_modules" ]; then
        ln -s "$lib_dir/node_modules" "$WORKTREE/onchain/lib/$lib_name/node_modules" 2>/dev/null || true
      fi
    done
  fi
fi

# =============================================================================
# BUILD PROMPT
# =============================================================================
OPEN_ISSUES_SUMMARY=$(forge_api GET "/issues?state=open&labels=backlog&limit=20&type=issues" | \
  jq -r '.[] | "#\(.number) \(.title)"' 2>/dev/null || echo "(could not fetch)")

PUSH_INSTRUCTIONS=$(build_phase_protocol_prompt "$BRANCH" "$FORGE_REMOTE")

# Load lessons from .profile repo if available (pre-session)
profile_load_lessons || true
LESSONS_INJECTION="${LESSONS_CONTEXT:-}"

if [ "$RECOVERY_MODE" = true ]; then
  GIT_DIFF_STAT=$(git -C "$WORKTREE" diff "${FORGE_REMOTE}/${PRIMARY_BRANCH}..HEAD" --stat 2>/dev/null \
    | head -20 || echo "(no diff)")
  REVIEW_FEEDBACK="$(pr_review_feedback "$PR_NUMBER")" || REVIEW_FEEDBACK=""

  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
This is issue #${ISSUE} for the ${FORGE_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

## CRASH RECOVERY

Your previous session for this issue was interrupted. Resume from where you left off.
Git is the checkpoint — your code changes survived.

### Work completed before crash:
\`\`\`
${GIT_DIFF_STAT}
\`\`\`

### PR: #${PR_NUMBER} (${BRANCH})
**IMPORTANT: PR #${PR_NUMBER} already exists — do NOT create a new PR.**
${REVIEW_FEEDBACK:+
### Review to address (the latest review of the current head)
${REVIEW_FEEDBACK}
}

### Next steps
1. Run \`git log --oneline -5\` and \`git status\` to understand current state.
2. Read AGENTS.md for project conventions.
3. Address any pending review comments or CI failures.
4. Commit and push to \`${BRANCH}\`.

${LESSONS_INJECTION:+## Lessons learned
${LESSONS_INJECTION}

}
${PUSH_INSTRUCTIONS}"
elif [ "${CARRY_MODE:-false}" = true ]; then
  GIT_DIFF_STAT=$(git -C "$WORKTREE" diff "${FORGE_REMOTE}/${PRIMARY_BRANCH}..HEAD" --stat 2>/dev/null \
    | head -20 || echo "(no diff)")

  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
This is issue #${ISSUE} for the ${FORGE_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

## CARRY OVER

Your previous session for this issue was stopped by a resource limit before it
could push. Its work was saved as a local commit on this branch. Resume from
where you left off.

### Work completed before the stop:
\`\`\`
${GIT_DIFF_STAT}
\`\`\`

### Next steps
1. Run \`git log --oneline -5\` and \`git status\` to understand current state.
2. Read AGENTS.md for project conventions.
3. Continue implementing the issue.
4. Commit and push to \`${BRANCH}\`.
5. If CI fails or review is pending, address them.

${LESSONS_INJECTION:+## Lessons learned
${LESSONS_INJECTION}

}
${PUSH_INSTRUCTIONS}"
else
  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
You have been assigned issue #${ISSUE} for the ${FORGE_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

## Other open issues labeled 'backlog' (for context):
${OPEN_ISSUES_SUMMARY}

$(if [ -n "$PRIOR_ART_DIFF" ]; then
  printf '## Prior Art (closed PR — DO NOT start from scratch)\n\nA previous PR attempted this issue but was closed without merging. Reuse as much as possible.\n\n```diff\n%s\n```\n' "$PRIOR_ART_DIFF"
fi)
${LESSONS_INJECTION:+## Lessons learned
${LESSONS_INJECTION}

}
## Instructions

1. Read AGENTS.md in this repo for project context and coding conventions.
2. Implement the changes described in the issue.
3. Run lint and tests before you're done (see AGENTS.md for commands).
4. Commit your changes with message: fix: ${ISSUE_TITLE} (#${ISSUE})
5. Push your branch.

If you cannot implement this issue, write ONLY a JSON object to ${IMPL_SUMMARY_FILE}:
- Unmet dependency: {\"status\":\"unmet_dependency\",\"blocked_by\":\"what's missing\",\"suggestion\":<number-or-null>}
- Too large: {\"status\":\"too_large\",\"reason\":\"explanation\"}
- Needs ops access: {\"status\":\"needs_ops\",\"reason\":\"what access is missing\"}
- Design conflict: {\"status\":\"design_conflict\",\"reason\":\"the contradiction\"}
- Already done: {\"status\":\"already_done\",\"reason\":\"where\"}

${PUSH_INSTRUCTIONS}"
fi

# =============================================================================
# NO-PUSH DECISION (#1164)
# =============================================================================
# no_push_outcome — decide what to do when agent_run finished without pushing.
#
# A run stopped by a resource limit (max turns, the wall-clock timeout, or a
# no_result terminal row — the harness never wrote a normal result row, i.e.
# server/harness death rather than "agent chose not to push") is a TRANSIENT
# failure: the issue goes back to the claimable backlog (issue_requeue)
# instead of "blocked", so a fresh run can retry it. On the third consecutive
# resource-limit exit (attempt >= 2, 0-indexed count of existing
# fix/issue-N* branches) the repeated limit means a human decision is needed,
# so the issue is blocked with a distinct reason. Any other no-push reason
# keeps the historical issue_block "no_push" behavior.
#
# #1647: before issue_block / issue_requeue, set _PR_WALK_EXIT_REASON to the
# reason this path acts on (re-queue: the requeue_reason — timeout,
# error_max_turns, or no_result; block: no_push_after_3_attempts or no_push).
# no_push_outcome runs in the main shell, so the EXIT trap's
# close_dev_tape_outcome sees the value and maps it through rubrics/dev.toml
# the same way as any failed walk. Not local — a local would hide it from the
# trap.
#
# Args: issue diag_file agent_run_rc attempt result_text
no_push_outcome() {
  local issue="$1" diag_file="$2" agent_run_rc="$3" attempt="${4:-0}" result_text="${5:-}"
  local subtype requeue_reason=""

  # The terminal stream-json row carries the run's subtype ("success",
  # "error_max_turns", or "no_result" — the latter written by the harness when
  # it died before a normal result row, e.g. server crash or llama 503).
  # The diag file may be a multi-line stream, a single nudge object, or a line
  # truncated by a watchdog kill — parse line by line and keep the last
  # result row's subtype.
  subtype=$(jq -R -s -r '
    split("\n")
    | map(select(. != "") | (try fromjson))
    | map(select(type == "object"))
    | [ .[] | select(.type == "result") | .subtype ]
    | last // ""
  ' "$diag_file" 2>/dev/null) || subtype=""

  case "$agent_run_rc" in '' | *[!0-9]*) agent_run_rc=0 ;; esac
  case "$attempt" in '' | *[!0-9]*) attempt=0 ;; esac

  # Last-result-row subtype picks a requeue reason: the turn cap, or the
  # no_result terminal row (harness death — not a push decision).
  case "$subtype" in
    error_max_turns) requeue_reason="error_max_turns" ;;
    no_result)       requeue_reason="no_result" ;;
  esac
  # rc 124 is the wall-clock timeout ceiling (agent_run contract) and is the
  # more recent event, so it wins when both signals are present.
  if [ "$agent_run_rc" -eq 124 ]; then
    requeue_reason="timeout"
  fi

  if [ -n "$requeue_reason" ]; then
    if [ "$attempt" -ge 2 ]; then
      # Cap fires: the work is abandoned, so nothing to carry forward.
      DEV_CARRY=0
      _PR_WALK_EXIT_REASON="no_push_after_3_attempts"
      issue_block "$issue" "no_push_after_3_attempts" \
        "Resource limit (${requeue_reason}) on attempt $((attempt + 1)) — Claude did not push branch ${BRANCH}"
    else
      # Transient resource limit: hand the in-progress work to the next attempt.
      DEV_CARRY=1
      _PR_WALK_EXIT_REASON="$requeue_reason"
      issue_requeue "$issue" "$requeue_reason" \
        "Resource limit (${requeue_reason}) — Claude did not push branch ${BRANCH}"
    fi
  else
    # Non-resource-limit no-push (agent chose not to, etc.): not transient.
    DEV_CARRY=0
    _PR_WALK_EXIT_REASON="no_push"
    issue_block "$issue" "no_push" "$result_text"
  fi
}

# dev_failed_attempts ID — count the proposal's failed attempts from the tape
# (#1646). A run that pushed nothing never grows the branch count, so the
# tape is the ledger, not ATTEMPT: count this proposal's outcome records whose
# merged is 0 or false and whose rejected is not 1 or true. Empty ID or a
# missing tape -> 0; malformed lines are skipped; never fails the pick.
dev_failed_attempts() {
  local id="$1"
  local tape_file count

  tape_file="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"
  if [ -z "$id" ] || [ ! -f "$tape_file" ]; then
    printf '0\n'
    return 0
  fi
  count="$(jq -R -s -r --arg id "$id" 'split("\n") | map(select(. != "")) | map(try fromjson | select(type == "object")) | [ .[] | select(.type == "outcome") | select(.proposal_id == $id) | select((.bits.merged == 0) or (.bits.merged == false)) | select(.bits.rejected != 1 and .bits.rejected != true) ] | length' "$tape_file" 2>/dev/null)" || count=0
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$count"
  else
    printf '0\n'
  fi
  return 0
}

# =============================================================================
# REFUSAL HANDLING (#1613)
# =============================================================================
#
# _dev_refusal_relabel — the shared tail of the refusal paths that leave the
# issue out of the dev queue (too_large, needs_ops, design_conflict,
# unmet_dependency): add the given label and drop backlog + in-progress. Labels
# are looked up by name via forge_api; every mutation is guarded so an API
# hiccup never aborts the run
# (matching the pre-#1613 too_large block).
_dev_refusal_relabel() {
  local issue="$1" label_name="$2"
  local label_id backlog_id in_progress_id

  label_id=$(forge_api GET "/labels" 2>/dev/null \
    | jq -r --arg n "$label_name" '.[] | select(.name == $n) | .id' 2>/dev/null || true)
  if [ -n "$label_id" ]; then
    forge_api POST "/issues/${issue}/labels" \
      -d "{\"labels\":[${label_id}]}" >/dev/null 2>&1 || true
  fi

  backlog_id=$(forge_api GET "/labels" 2>/dev/null \
    | jq -r --arg n "backlog" '.[] | select(.name == $n) | .id' 2>/dev/null || true)
  if [ -n "$backlog_id" ]; then
    forge_api DELETE "/issues/${issue}/labels/${backlog_id}" >/dev/null 2>&1 || true
  fi

  in_progress_id=$(forge_api GET "/labels" 2>/dev/null \
    | jq -r --arg n "in-progress" '.[] | select(.name == $n) | .id' 2>/dev/null || true)
  if [ -n "$in_progress_id" ]; then
    forge_api DELETE "/issues/${issue}/labels/${in_progress_id}" >/dev/null 2>&1 || true
  fi
}

# handle_refusal — act on the refusal summary the agent wrote to the summary
# file.
#
# Args: STATUS (the .status field) REFUSAL_JSON (the raw JSON object).
#
# Statuses and behavior:
#   * unmet_dependency -> refusal comment (+ the "closed dep may not have
#       landed" note); add `blocked`, drop backlog + in-progress (#1672).
#   * too_large        -> refusal comment; add `underspecified`, drop
#       backlog + in-progress (pre-#1613).
#   * already_done     -> refusal comment, close the issue (pre-#1613).
#   * needs_ops        -> refusal comment (body = reason); add `rejected`,
#       drop backlog + in-progress. (#1613) The issue needs access this repo's
#       code change can't provide: a secret, the ops repo, a running host, or
#       a human step.
#   * design_conflict  -> refusal comment (body = reason); add `rejected`,
#       drop backlog + in-progress. (#1613) The issue contradicts the current
#       code or a design document it cites; name both sides in the reason.
#   * (anything else)  -> no-op on the issue (pre-#1613 behavior: no
#       comment, no relabel; the caller still cleans up the worktree and exits).
handle_refusal() {
  local status="$1" refusal_json="${2:-}"
  local reason blocked_by_msg suggestion comment_body

  # #1608: record the disposition status so close_dev_tape_outcome() (run from
  # the EXIT trap, same process) can write rejected: 1 + a reason. Only the
  # four disposition statuses qualify: unmet_dependency blocks the issue instead
  # of re-queueing it (not a disposition, #1672) and unknown statuses are a
  # no-op, so neither is recorded — both then take the failure-walk shape in
  # the outcome.
  # (The pattern is one unspaced `a|b|c|d)` line so the first token is followed
  # by `|` and correctly skipped by the CI function-resolver, which otherwise
  # would treat a spaced `a | b)` first token as an undefined call.)
  case "$status" in
    too_large|already_done|needs_ops|design_conflict)
      _DEV_REFUSAL_STATUS="$status"
      ;;
  esac

  case "$status" in
    unmet_dependency)
      blocked_by_msg=$(printf '%s' "$refusal_json" | jq -r '.blocked_by // "unknown"')
      suggestion=$(printf '%s' "$refusal_json" | jq -r '.suggestion // empty')
      comment_body="### Blocked by unmet dependency

  ${blocked_by_msg}"
      [ -n "$suggestion" ] && [ "$suggestion" != "null" ] && \
        comment_body="${comment_body}

  **Suggestion:** Work on #${suggestion} first."
      # #1672: dev-poll only claims issues whose declared deps are all closed,
      # so an unmet_dependency refusal means a closed dependency's work may
      # never have landed. Block instead of re-queueing: a release would be
      # picked, refused and re-queued at once by dev-poll (#1622).
      comment_body="${comment_body}

  dev-poll found every dependency closed, so a closed dependency may not have landed. Re-add backlog once it has."
      issue_post_refusal "$ISSUE" "🚧" "Unmet dependency" "$comment_body"
      _dev_refusal_relabel "$ISSUE" "blocked"
      CLAIMED=false
      ;;
    too_large)
      reason=$(printf '%s' "$refusal_json" | jq -r '.reason // "unspecified"')
      issue_post_refusal "$ISSUE" "📏" "Too large for single session" \
        "### Why this can't be implemented as-is

  ${reason}

  ### Next steps
  A maintainer should split this issue or add more detail to the spec."
      # Add underspecified label, remove backlog + in-progress
      _dev_refusal_relabel "$ISSUE" "underspecified"
      CLAIMED=false
      ;;
    already_done)
      reason=$(printf '%s' "$refusal_json" | jq -r '.reason // "unspecified"')
      issue_post_refusal "$ISSUE" "✅" "Already implemented" \
        "### Existing implementation

  ${reason}

  Closing as already implemented."
      issue_close "$ISSUE"
      CLAIMED=false
      ;;
    needs_ops)
      # Refusal needs access this repo's code change can't provide: a secret,
      # the ops repo, a running host, or a human step.
      reason=$(printf '%s' "$refusal_json" | jq -r '.reason // "unspecified"')
      issue_post_refusal "$ISSUE" "🔧" "Needs ops access" "$reason"
      _dev_refusal_relabel "$ISSUE" "rejected"
      CLAIMED=false
      ;;
    design_conflict)
      # The issue contradicts the current code or a design document it cites;
      # name both sides in the reason.
      reason=$(printf '%s' "$refusal_json" | jq -r '.reason // "unspecified"')
      issue_post_refusal "$ISSUE" "⚠️" "Design conflict" "$reason"
      _dev_refusal_relabel "$ISSUE" "rejected"
      CLAIMED=false
      ;;
    *)
      # Unknown status: no-op on the issue (pre-#1613 behavior).
      :
      ;;
  esac
}

# IMPLEMENT
# =============================================================================
status "running implementation"
echo '{"status":"ready"}' > "$PREFLIGHT_RESULT"
# Refusal protocol (see INITIAL_PROMPT) uses shell expansion
# ("> $IMPL_SUMMARY_FILE"); export it so dsh agents resolve the real path
# instead of guessing (same class as review-pr.sh REVIEW_OUTPUT_FILE).
export IMPL_SUMMARY_FILE

# Key the tape run off the pick's proposal id (#1440): dev-poll wrote the
# picked issue's proposal id to this project-scoped id file at pick time
# (#1398; contents: just the id), and formula-session attaches the run
# record to $TAPE_PROPOSAL_ID when set (#1391) — so the run pairs with the
# pick instead of a fresh ULID. Missing or empty id file (issue predates
# the pick step) → leave unset; the run keys on its own ULID as before.
# No proposal record is created here.
PROPOSAL_ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME:-default}-${ISSUE}"
if [ -s "$PROPOSAL_ID_FILE" ]; then
  PROPOSAL_ID="$(cat "$PROPOSAL_ID_FILE" 2>/dev/null || true)"
  if [ -n "$PROPOSAL_ID" ]; then
    export TAPE_PROPOSAL_ID="$PROPOSAL_ID"
    log "tape: keying run off pick proposal ${PROPOSAL_ID}"
  fi
fi

# #1646: the retry budget is this proposal's ledger of failed attempts from the
# tape — outcomes that neither merged nor were rejected — not the branch count.
# A run that pushed nothing never grew the branch count, so the old ATTEMPT
# counter sat at 0 and the cap never fired. 1-based: failed + 1.
DEV_FAILED_ATTEMPTS="$(dev_failed_attempts "${PROPOSAL_ID:-}")"
TAPE_RUN_ATTEMPTS=$((DEV_FAILED_ATTEMPTS + 1))
export TAPE_RUN_ATTEMPTS

# Open the proposal-loop tape run record (#1391) — total, never fails us
formula_session_start "dev"

# Capture agent_run's exit code (its contract: 124 = wall-clock timeout,
# #1164). Unguarded, a non-zero return would abort this set -e script before
# the no-push decision below ever runs.
AGENT_RUN_RC=0
if [ -n "$_AGENT_SESSION_ID" ]; then
  agent_run --resume "$_AGENT_SESSION_ID" --worktree "$WORKTREE" --task "$ISSUE" "$INITIAL_PROMPT" || AGENT_RUN_RC=$?
else
  agent_run --worktree "$WORKTREE" --task "$ISSUE" "$INITIAL_PROMPT" || AGENT_RUN_RC=$?
fi

# Close the tape run: outcome + closing run record (#1391)
formula_session_end "$AGENT_RUN_RC"

# =============================================================================
# CHECK RESULT: did Claude push?
# =============================================================================
REMOTE_SHA=$(git ls-remote "$FORGE_REMOTE" "refs/heads/${BRANCH}" 2>/dev/null \
  | awk '{print $1}') || true

if [ -z "$REMOTE_SHA" ]; then
  # Check for refusal in summary file
  if [ -f "$IMPL_SUMMARY_FILE" ] && jq -e '.status' < "$IMPL_SUMMARY_FILE" >/dev/null 2>&1; then
    REFUSAL_JSON=$(cat "$IMPL_SUMMARY_FILE")
    REFUSAL_STATUS=$(printf '%s' "$REFUSAL_JSON" | jq -r '.status')
    log "claude refused: ${REFUSAL_STATUS}"
    printf '%s' "$REFUSAL_JSON" > "$PREFLIGHT_RESULT"

    handle_refusal "$REFUSAL_STATUS" "$REFUSAL_JSON"
    worktree_cleanup "$WORKTREE"
    rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE" "$CARRY_FILE"
    exit 0
  fi

  log "ERROR: no branch pushed after agent_run"
  # Dump diagnostics
  diag_file="${DISINTO_LOG_DIR:-/tmp}/dev/agent-run-last.json"
  if [ -f "$diag_file" ]; then
    result_text=""; cost_usd=""; num_turns=""
    result_text=$(jq -r '.result // "no result field"' "$diag_file" 2>/dev/null | head -50) || result_text="(parse error)"
    cost_usd=$(jq -r '.cost_usd // "?"' "$diag_file" 2>/dev/null) || cost_usd="?"
    num_turns=$(jq -r '.num_turns // "?"' "$diag_file" 2>/dev/null) || num_turns="?"
    log "no_push diagnostics: turns=${num_turns} cost=${cost_usd}"
    log "no_push result: ${result_text}"
    # Save full output for later analysis
    cp "$diag_file" "${DISINTO_LOG_DIR:-/tmp}/dev/no-push-${ISSUE}-$(date +%s).json" 2>/dev/null || true
  fi

  # Save full session log for debugging
  # Session logs are stored in CLAUDE_CONFIG_DIR/projects/{worktree-hash}/{session-id}.jsonl
  _wt_hash=$(printf '%s' "$WORKTREE" | md5sum | cut -c1-12)
  _cl_config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  _session_log="${_cl_config}/projects/${_wt_hash}/${_AGENT_SESSION_ID}.jsonl"
  if [ -f "$_session_log" ]; then
    cp "$_session_log" "${DISINTO_LOG_DIR}/dev/no-push-session-${ISSUE}-$(date +%s).jsonl" 2>/dev/null || true
    log "no_push session log saved to ${DISINTO_LOG_DIR}/dev/no-push-session-${ISSUE}-*.jsonl"
  fi

  # Log session summary for debugging
  if [ -f "$_session_log" ]; then
    _read_calls=$(grep -c '"type":"read"' "$_session_log" 2>/dev/null || echo "0")
    _edit_calls=$(grep -c '"type":"edit"' "$_session_log" 2>/dev/null || echo "0")
    _bash_calls=$(grep -c '"type":"bash"' "$_session_log" 2>/dev/null || echo "0")
    _text_calls=$(grep -c '"type":"text"' "$_session_log" 2>/dev/null || echo "0")
    _failed_calls=$(grep -c '"exit_code":null' "$_session_log" 2>/dev/null || echo "0")
    _total_turns=$(grep -c '"type":"turn"' "$_session_log" 2>/dev/null || echo "0")
    log "no_push session summary: turns=${_total_turns} reads=${_read_calls} edits=${_edit_calls} bash=${_bash_calls} text=${_text_calls} failed=${_failed_calls}"
  fi

  no_push_outcome "$ISSUE" "$diag_file" "$AGENT_RUN_RC" "${DEV_FAILED_ATTEMPTS:-0}" \
    "Claude did not push branch ${BRANCH}"
  CLAIMED=false
  if [ "${DEV_CARRY:-0}" = "1" ]; then
    # Hand the in-progress work to the next attempt: commit it as a local
    # "wip" commit and keep both the worktree and the session.
    dev_carry_save "$WORKTREE" "$BRANCH"
    log "carry: keeping worktree ${WORKTREE} and session for the next attempt"
  else
    worktree_cleanup "$WORKTREE"
    rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE" "$CARRY_FILE"
  fi
  exit 1
fi

log "branch pushed: ${REMOTE_SHA:0:7}"

# =============================================================================
# CREATE PR (if not in recovery mode)
# =============================================================================
if [ -z "$PR_NUMBER" ]; then
  status "creating PR"
  IMPL_SUMMARY=""
  if [ -f "$IMPL_SUMMARY_FILE" ]; then
    if ! jq -e '.status' < "$IMPL_SUMMARY_FILE" >/dev/null 2>&1; then
      IMPL_SUMMARY=$(head -c 4000 "$IMPL_SUMMARY_FILE")
    fi
  fi

  PR_BODY=$(printf 'Fixes #%s\n\n## Changes\n%s' "$ISSUE" "$IMPL_SUMMARY")
  PR_TITLE="fix: ${ISSUE_TITLE} (#${ISSUE})"
  PR_NUMBER=$(pr_create "$BRANCH" "$PR_TITLE" "$PR_BODY") || true

  if [ -z "$PR_NUMBER" ]; then
    log "ERROR: failed to create PR"
    issue_block "$ISSUE" "pr_create_failed"
    rm -f "$CARRY_FILE"
    CLAIMED=false
    exit 1
  fi
  log "created PR #${PR_NUMBER}"
fi

# =============================================================================
# WALK PR TO MERGE
# =============================================================================
status "walking PR #${PR_NUMBER} to merge"

rc=0
pr_walk_to_merge "$PR_NUMBER" "$_AGENT_SESSION_ID" "$WORKTREE" 3 5 || rc=$?
PR_WALK_RC="$rc"

if [ "$rc" -eq 0 ]; then
  # Merged successfully — keep open with awaiting-live-verification label
  log "PR #${PR_NUMBER} merged"
  issue_close_after_verification "$ISSUE"

  # Capture files changed for journal entry (after agent work)
  FILES_CHANGED=$(git -C "$WORKTREE" diff "${FORGE_REMOTE}/${PRIMARY_BRANCH}..HEAD" --name-only 2>/dev/null | tr '\n' ',' | sed 's/,$//') || FILES_CHANGED=""

  # Write journal entry post-session (before cleanup)
  profile_write_journal "$ISSUE" "$ISSUE_TITLE" "merged" "$FILES_CHANGED" || true

  # Pull primary branch and push to mirrors
  git -C "$REPO_ROOT" fetch "$FORGE_REMOTE" "$PRIMARY_BRANCH" 2>/dev/null || true
  git -C "$REPO_ROOT" checkout "$PRIMARY_BRANCH" 2>/dev/null || true
  git -C "$REPO_ROOT" pull --ff-only "$FORGE_REMOTE" "$PRIMARY_BRANCH" 2>/dev/null || true
  mirror_push

  worktree_cleanup "$WORKTREE"
  rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE" "$CARRY_FILE"
  CLAIMED=false
else
  # Exhausted or unrecoverable failure
  log "PR walk failed: ${_PR_WALK_EXIT_REASON:-unknown}"
  if dev_walk_reason_terminal "${_PR_WALK_EXIT_REASON:-}"; then
    # Terminal reason (ci_exhausted, review_exhausted, merge_blocked,
    # closed_externally, ...): the walk is truly over — block the issue and
    # record the blocked outcome, as today.
    issue_block "$ISSUE" "${_PR_WALK_EXIT_REASON:-agent_failed}"
    outcome="blocked_${_PR_WALK_EXIT_REASON:-agent_failed}"
  else
    # ci_timeout: the walk ran out of CI-wait time while CI was still running.
    # Nothing failed — the PR is still open. Do not block the issue and do not
    # write a terminal tape outcome (the EXIT trap skips it, #1705); dev-poll's
    # in-progress scan owns the PR from here (it merges, spawns a CI fix, or
    # waits, and emits its own outcome when the PR lands).
    log "CI still running on PR #${PR_NUMBER}: #${ISSUE} stays in progress; dev-poll takes it from here"
    outcome="waiting_ci"
  fi

  # Capture files changed for journal entry (after agent work)
  FILES_CHANGED=$(git -C "$WORKTREE" diff "${FORGE_REMOTE}/${PRIMARY_BRANCH}..HEAD" --name-only 2>/dev/null | tr '\n' ',' | sed 's/,$//') || FILES_CHANGED=""

  # Write journal entry post-session (before cleanup)
  profile_write_journal "$ISSUE" "$ISSUE_TITLE" "$outcome" "$FILES_CHANGED" || true

  # Cleanup on failure: preserve remote branch and PR for debugging, clean up local worktree
  # Remote state (PR and branch) stays open for inspection of CI logs and review comments
  worktree_cleanup "$WORKTREE"
  rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE" "$CARRY_FILE"
  CLAIMED=false
fi

log "dev-agent finished for issue #${ISSUE}"
