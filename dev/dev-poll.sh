#!/usr/bin/env bash
# dev-poll.sh — Pull-based scheduler: find the next ready issue and start dev-agent
#
# SDK version: No tmux — checks PID lockfile for active agents.
# Uses pr_merge() and issue_block() from shared libraries.
#
# Pull system: issues labeled "backlog" are candidates. An issue is READY when
# ALL its dependency issues are closed (and their PRs merged).
# No "todo" label needed — readiness is derived from reality.
#
# Priority:
#   1. Orphaned "in-progress" issues (agent died or PR needs attention)
#   2. Ready "priority" + "backlog" issues (FIFO within tier)
#   3. Ready "backlog" issues without "priority" (FIFO within tier)
#
# Usage:
#   Called by: entrypoint.sh polling loop (every 10 min)
#   dev-poll.sh [projects/harb.toml]   # optional project config

set -euo pipefail

# Load shared environment and libraries
export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
# shellcheck source=../lib/pr-lifecycle.sh
source "$(dirname "$0")/../lib/pr-lifecycle.sh"
# shellcheck source=../lib/issue-lifecycle.sh
source "$(dirname "$0")/../lib/issue-lifecycle.sh"
# shellcheck source=../lib/mirrors.sh
source "$(dirname "$0")/../lib/mirrors.sh"
# shellcheck source=../lib/guard.sh
source "$(dirname "$0")/../lib/guard.sh"
# shellcheck source=../lib/ci-fix-tracker.sh
source "$(dirname "$0")/../lib/ci-fix-tracker.sh"
check_active dev

# Initialize CI fix tracker (must be called before any tracker functions)
ci_fix_tracker_init

API="${FORGE_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-default}.lock"
LOGFILE="${DISINTO_LOG_DIR}/dev/dev-agent-${PROJECT_NAME:-default}.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# Record what this run actually resolved (#1070). One dev-agent run was seen
# holding PROJECT_NAME from one project and FORGE_REPO from another, which
# produced a worktree named for one project working an issue from the other.
# Every path below is derived from one of these four values, so logging them
# at entry makes the next occurrence explain itself.
log "context: PROJECT_TOML=${PROJECT_TOML:-(unset)} PROJECT_NAME=${PROJECT_NAME:-(unset)} FORGE_REPO=${FORGE_REPO:-(unset)} FORGE_API=${FORGE_API:-(unset)} LOCKFILE=${LOCKFILE}"

# Resolve current agent identity once at startup — cache for all assignee checks
BOT_USER=$(forge_whoami)
log "running as agent: ${BOT_USER}"

# Check whether an issue already has the "blocked" label
is_blocked() {
  local issue="$1"
  forge_api GET "/issues/${issue}/labels" 2>/dev/null \
    | jq -e '.[] | select(.name == "blocked")' >/dev/null 2>&1
}

# =============================================================================
# STALENESS DETECTION FOR IN-PROGRESS ISSUES
# =============================================================================

# Check if in-progress label was added recently (within grace period).
# Prevents race where a poller marks an issue as stale before the claiming
# agent's assign + label sequence has fully propagated. See issue #471.
# Args: issue_number [grace_seconds]
# Returns: 0 if recently added (within grace period), 1 if not
in_progress_recently_added() {
  local issue="$1" grace="${2:-60}"
  local now label_ts delta

  now=$(date +%s)

  # Query issue timeline for the most recent in-progress label event.
  # Forgejo 11.x API returns type as string "label", not integer 7.
  label_ts=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${issue}/timeline" | \
    jq -r '[.[] | select(.type == "label") | select(.label.name == "in-progress")] | last | .created_at // empty') || true

  if [ -z "$label_ts" ]; then
    return 1  # no label event found — not recently added
  fi

  # Convert ISO timestamp to epoch and compare
  local label_epoch
  label_epoch=$(date -d "$label_ts" +%s 2>/dev/null || echo 0)
  delta=$(( now - label_epoch ))

  if [ "$delta" -lt "$grace" ]; then
    return 0  # within grace period
  fi
  return 1
}

# Print the number of the most recently merged PR targeting the issue's
# branch, or nothing if there is none.
#
# A merged PR is proof of completion, not staleness (#1130). The sweep only
# sees OPEN PRs, but a merged PR is state=closed — so it must be looked up
# explicitly with state=all.
#
# Every attempt after the first is named fix/issue-N-<attempt> by
# dev-agent.sh, so the match must cover the suffixed retry branches too
# (#1137) — anchored, so fix/issue-113 cannot match issue 1130.
#
# Args: issue_number
merged_pr_for_issue() {
  local issue="$1"
  forge_api GET "/pulls?state=all&limit=50" 2>/dev/null |
    jq -r --arg issue "$issue" \
      '[.[] | select(.head.ref | test("^fix/issue-" + $issue + "(-[0-9]+)?$"))
        | select(.merged == true)] | last | .number // empty' || true
}

# Relabel a stale in-progress issue to blocked with diagnostic comment
# Args: issue_number reason
# Uses shared helpers from lib/issue-lifecycle.sh
relabel_stale_issue() {
  local issue="$1" reason="$2"

  log "relabeling stale in-progress issue #${issue} to blocked: ${reason}"

  # Remove in-progress label
  local ip_id
  ip_id=$(_ilc_in_progress_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${issue}/labels/${ip_id}" >/dev/null 2>&1 || true
  fi

  # Add blocked label
  local bk_id
  bk_id=$(_ilc_blocked_id)
  if [ -n "$bk_id" ]; then
    curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${issue}/labels" \
      -d "{\"labels\":[${bk_id}]}" >/dev/null 2>&1 || true
  fi

  # Post diagnostic comment using shared helper
  local comment_body
  comment_body=$(
    printf '%s\n\n' '### Stale in-progress issue detected'
    printf '%s\n' '| Field | Value |'
    printf '%s\n' '|---|---|'
    printf '| Detection reason | `%s` |\n' "$reason"
    printf '| Timestamp | `%s` |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' '**Status:** This issue was labeled `in-progress` but has no assignee, no open PR, and no agent lock file.'
    printf '%s\n' '**Action required:** A maintainer should triage this issue.'
  )
  _ilc_post_comment "$issue" "$comment_body"

  _ilc_log "stale issue #${issue} relabeled to blocked: ${reason}"
}

# =============================================================================
# Handle an in-progress issue that has no assignee, no open PR, and no agent
# lock — the "stale" case of the sweep above.
#
# A merged PR is proof of completion, not staleness (#1130): between the
# moment a PR merges and the moment the issue is closed, the issue sits in
# exactly this state, which the open-PR-only check cannot distinguish from
# abandonment — observed on #1094, relabeled "blocked" 24s after its PR
# merged. When a linked PR is merged, close the issue instead of relabeling
# it "blocked". Otherwise relabel it blocked, as before.
#
# Args: issue_number
# =============================================================================
handle_stale_in_progress() {
  local issue="$1"
  local merged_pr
  merged_pr=$(merged_pr_for_issue "$issue")
  if [ -n "$merged_pr" ]; then
    log "issue #${issue} has merged PR #${merged_pr} — closing instead of relabeling to blocked (#1130)"
    issue_close "$issue"
    # Remove the in-progress label (issue is closed — mirror try_direct_merge)
    local ip_id
    ip_id=$(_ilc_in_progress_id)
    if [ -n "$ip_id" ]; then
      curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/issues/${issue}/labels/${ip_id}" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  log "issue #${issue} is stale (no assignee, no open PR, no agent lock) — relabeling to blocked"
  relabel_stale_issue "$issue" "no_assignee_no_open_pr_no_lock"
}

# =============================================================================
# HELPER: handle CI-exhaustion check/block (DRY for 3 call sites)
# Sets CI_FIX_ATTEMPTS for caller use. Returns 0 if exhausted, 1 if not.
# Uses issue_block() from lib/issue-lifecycle.sh for blocking.
#
# Pass "check_only" as third arg for the backlog scan path: ok-counts are
# returned without incrementing (deferred to launch time so a WAITING_PRS
# exit cannot waste a fix attempt). The 3->4 sentinel bump is always atomic.
# =============================================================================
handle_ci_exhaustion() {
  local pr_num="$1" issue_num="$2"
  local check_only="${3:-}"
  local result

  # Fast path: already blocked — skip without touching counter.
  if is_blocked "$issue_num"; then
    CI_FIX_ATTEMPTS=$(ci_fix_tracker_count "$pr_num")
    log "PR #${pr_num} (issue #${issue_num}) already blocked (${CI_FIX_ATTEMPTS} attempts) — skipping"
    return 0
  fi

  result=$(ci_fix_tracker_check_and_increment "$pr_num" "$check_only")
  case "$result" in
    ok:*)
      CI_FIX_ATTEMPTS="${result#ok:}"
      return 1
      ;;
    exhausted_first_time:*)
      CI_FIX_ATTEMPTS="${result#exhausted_first_time:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — marking blocked"
      issue_block "$issue_num" "ci_exhausted_poll (${CI_FIX_ATTEMPTS} attempts, PR #${pr_num})"
      ;;
    exhausted:*)
      CI_FIX_ATTEMPTS="${result#exhausted:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — already blocked, skipping"
      ;;
    *)
      CI_FIX_ATTEMPTS=99
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — already blocked, skipping"
      ;;
  esac
  return 0
}

# =============================================================================
# HELPER: merge an approved PR directly via pr_merge() (no Claude needed)
#
# Merging an approved, CI-green PR is a single API call. Spawning dev-agent
# for this fails when the issue is already closed (forge auto-closes issues
# on PR creation when body contains "Fixes #N"), causing a respawn loop (#344).
#
# A merge blocked for the same reason at the same head (e.g. branch
# protection requires a status check CI can never report) is escalated once
# after MERGE_BLOCK_RETRY_LIMIT identical failures instead of retrying every
# poll cycle forever (#1090).
#
# Args: pr_num issue_num [head_sha]
# Returns: 0=merged, 1=failed (caller may fall back to dev-agent),
#          2=merge-blocked and escalated (caller must NOT retry or spawn)
# =============================================================================
try_direct_merge() {
  local pr_num="$1" issue_num="$2"
  local head_sha="${3:-}"

  # Already escalated for this exact head SHA: retrying is pointless and the
  # dev-agent fallback cannot help either. A newer head SHA gets a fresh try.
  if [ -n "$head_sha" ] && pr_merge_block_escalated "$pr_num" "$head_sha"; then
    log "PR #${pr_num} (issue #${issue_num}) merge blocked and already escalated — not retrying (#1090)"
    return 2
  fi

  log "PR #${pr_num} (issue #${issue_num}) approved + CI green → attempting direct merge"

  local rc=0
  pr_merge "$pr_num" || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "PR #${pr_num} merged successfully"
    pr_merge_block_clear "$pr_num"
    if [ "$issue_num" -gt 0 ]; then
      issue_close "$issue_num"
      # Remove in-progress label (don't re-add backlog — issue is closed)
      IP_ID=$(_ilc_in_progress_id)
      curl -sf -X DELETE \
        -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/issues/${issue_num}/labels/${IP_ID}" >/dev/null 2>&1 || true
      rm -f "/tmp/dev-session-${PROJECT_NAME}-${issue_num}.sid" \
            "/tmp/dev-impl-summary-${PROJECT_NAME}-${issue_num}.txt"
    fi
    # Pull merged primary branch and push to mirrors
    git -C "${PROJECT_REPO_ROOT:-}" fetch origin "${PRIMARY_BRANCH:-}" 2>/dev/null || true
    git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH:-}" 2>/dev/null || true
    git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH:-}" 2>/dev/null || true
    mirror_push
    ci_fix_tracker_reset "$pr_num"
    return 0
  fi

  local decision
  decision=$(pr_merge_block_record "$pr_num" "${_PR_MERGE_HEAD_SHA:-${head_sha}}" "${_PR_MERGE_ERROR:-merge failed (HTTP ${rc})}") || decision="retry"
  case "$decision" in
    escalate)
      log "PR #${pr_num} (issue #${issue_num}) merge failing repeatedly with the same reason — escalating instead of retrying forever (#1090)"
      escalate_merge_blocked_pr "$pr_num" "$issue_num"
      return 2
      ;;
    skip)
      log "PR #${pr_num} (issue #${issue_num}) still merge-blocked, already escalated — not retrying (#1090)"
      return 2
      ;;
    *)
      log "PR #${pr_num} direct merge failed — falling back to dev-agent"
      return 1
      ;;
  esac
}

# =============================================================================
# HELPER: escalate a PR that can be neither picked up nor merged (#1089)
#
# A reopened PR whose reviews are all stale (Forgejo marks every review stale
# on close/reopen, including the one pinned to the head) can end up with zero
# LIVE reviews: no REQUEST_CHANGES to pick it up, no APPROVE to merge it.
# Nothing in the factory can move that PR — only a re-review can — so holding
# the queue for it wedges every other backlog issue. Instead, report it:
# post a dedup'd comment, label the issue "blocked", and drop "in-progress"
# so the next poll no longer treats it as in-flight work.
#
# Args: issue_num pr_num [head_sha]
# =============================================================================
escalate_wedged_pr() {
  local issue_num="$1" pr_num="$2"
  local head_sha="${3:-}"

  # Dedup: don't re-post (or re-relabel) if an escalation already exists.
  local marker
  marker="<!-- pr-wedged: ${pr_num} -->"
  local already
  already=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${issue_num}/comments?limit=10" 2>/dev/null \
    | jq -r --arg m "$marker" '[.[] | (.body // "") | contains($m)] | any | tostring') || true
  if [ "$already" = "true" ]; then
    log "PR #${pr_num} (issue #${issue_num}) already escalated — skipping"
    return 0
  fi

  local comment_body
  comment_body=$(
    printf '%s\n\n' "$marker"
    printf '%s\n' '### PR has no actionable next step'
    printf '%s\n' '| Field | Value |'
    printf '%s\n' '|---|---|'
    printf '| PR | #%s |\n' "$pr_num"
    printf '| Head SHA | `%s` |\n' "${head_sha:-unknown}"
    printf '| Timestamp | `%s` |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' '**Status:** CI is green, but the PR has no live review: every review is marked stale and none is pinned to the current head, so the factory can neither pick it up (no live REQUEST_CHANGES) nor merge it (no live APPROVE). This is the Forgejo close/reopen quirk where all reviews go stale (#1089). A human or bot re-review of the PR will unblock it automatically.'
  )
  _ilc_post_comment "$issue_num" "$comment_body"

  # Add blocked label
  local bk_id
  bk_id=$(_ilc_blocked_id)
  if [ -n "$bk_id" ]; then
    curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${issue_num}/labels" \
      -d "{\"labels\":[${bk_id}]}" >/dev/null 2>&1 || true
  fi

  # Remove in-progress label so the next poll no longer treats the issue
  # as in-flight (a claim clears "blocked" again — escalation is reversible).
  local ip_id
  ip_id=$(_ilc_in_progress_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${issue_num}/labels/${ip_id}" >/dev/null 2>&1 || true
  fi

  log "escalated PR #${pr_num} (issue #${issue_num}) — no actionable next step; queue not held (#1089)"
}

# =============================================================================
# HELPER: escalate a PR whose merge is repeatedly blocked for the same reason
#
# When the direct merge keeps failing with the same body on the same head
# (e.g. branch protection requires a status check that no pipeline reports,
# or a check CI can never pass), retrying every poll cycle is pure waste and
# the log fills with identical lines (#1090). Report it instead: post a
# dedup'd comment with the full, untruncated forge response, label the issue
# "blocked", and drop "in-progress" so the queue is not held.
#
# Args: pr_num issue_num
# =============================================================================
escalate_merge_blocked_pr() {
  local pr_num="$1" issue_num="${2:-0}"

  if [ "$issue_num" -le 0 ]; then
    log "PR #${pr_num} merge blocked and escalated, but no issue number — logging only"
    return 0
  fi

  # Dedup: don't re-post (or re-relabel) if an escalation already exists.
  local marker
  marker="<!-- pr-merge-blocked: ${pr_num} -->"
  local already
  already=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${issue_num}/comments?limit=10" 2>/dev/null \
    | jq -r --arg m "$marker" '[.[] | (.body // "") | contains($m)] | any | tostring') || true
  if [ "$already" = "true" ]; then
    log "PR #${pr_num} (issue #${issue_num}) merge-block escalation already posted — skipping"
    return 0
  fi

  local comment_body
  comment_body=$(
    printf '%s\n\n' "$marker"
    printf '%s\n' '### Merge repeatedly blocked'
    printf '%s\n' '| Field | Value |'
    printf '%s\n' '|---|---|'
    printf '| PR | #%s |\n' "$pr_num"
    printf '| Head SHA | `%s` |\n' "${_PR_MERGE_HEAD_SHA:-unknown}"
    if [ -n "${_PR_MERGE_MISSING_CONTEXTS:-}" ]; then
      printf '| Unsatisfied required checks | %s |\n' "${_PR_MERGE_MISSING_CONTEXTS}"
    fi
    printf '| Timestamp | `%s` |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' '**Status:** the direct merge keeps failing for the same reason on the same commit, so the factory stopped retrying it. Full forge response (untruncated):'
    printf '\n```\n%s\n```\n' "${_PR_MERGE_ERROR:-unknown}"
  )
  _ilc_post_comment "$issue_num" "$comment_body"

  # Add blocked label
  local bk_id
  bk_id=$(_ilc_blocked_id)
  if [ -n "$bk_id" ]; then
    curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${issue_num}/labels" \
      -d "{\"labels\":[${bk_id}]}" >/dev/null 2>&1 || true
  fi

  # Remove in-progress label so the next poll no longer treats the issue as
  # in-flight (a claim clears "blocked" again — escalation is reversible).
  local ip_id
  ip_id=$(_ilc_in_progress_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${issue_num}/labels/${ip_id}" >/dev/null 2>&1 || true
  fi

  log "escalated PR #${pr_num} (issue #${issue_num}) — merge blocked: ${_PR_MERGE_ERROR:-unknown} (#1090)"
}

# =============================================================================
# HELPER: extract issue number from PR branch/title/body
# =============================================================================
extract_issue_from_pr() {
  local branch="$1" title="$2" body="$3"
  local issue
  issue=$(echo "$branch" | grep -oP '(?<=fix/issue-)\d+' || true)
  if [ -z "$issue" ]; then
    issue=$(echo "$title" | grep -oP '#\K\d+' | tail -1 || true)
  fi
  if [ -z "$issue" ]; then
    issue=$(echo "$body" | grep -oiP '(?:closes|fixes|resolves)\s*#\K\d+' | head -1 || true)
  fi
  printf '%s' "$issue"
}

# =============================================================================
# DEPENDENCY HELPERS
# =============================================================================
dep_is_merged() {
  local dep_num="$1"
  local dep_state
  dep_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${dep_num}" | jq -r '.state // "open"')
  if [ "$dep_state" != "closed" ]; then
    return 1
  fi
  return 0
}

get_deps() {
  local issue_body="$1"
  echo "$issue_body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh"
}

issue_is_ready() {
  local issue_num="$1"
  local issue_body="$2"
  local deps
  deps=$(get_deps "$issue_body")

  if [ -z "$deps" ]; then
    return 0
  fi

  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if ! dep_is_merged "$dep"; then
      log "  #${issue_num} blocked: dep #${dep} not merged"
      return 1
    fi
  done <<< "$deps"

  return 0
}

# =============================================================================
# PRE-LOCK: merge approved + CI-green PRs (no Claude session needed)
#
# Merging is a single API call — it doesn't need the dev-agent lock.
# This ensures approved PRs get merged even while a dev-agent is running.
# (See #531: direct merges should not be blocked by agent lock)
# =============================================================================
log "pre-lock: scanning for mergeable PRs"
PL_PRS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

PL_MERGED_ANY=false
for i in $(seq 0 $(($(echo "$PL_PRS" | jq 'length') - 1))); do
  PL_PR_NUM=$(echo "$PL_PRS" | jq -r ".[$i].number")
  PL_PR_SHA=$(echo "$PL_PRS" | jq -r ".[$i].head.sha")
  PL_PR_BRANCH=$(echo "$PL_PRS" | jq -r ".[$i].head.ref")
  PL_PR_TITLE=$(echo "$PL_PRS" | jq -r ".[$i].title")
  PL_PR_BODY=$(echo "$PL_PRS" | jq -r ".[$i].body // \"\"")

  PL_ISSUE=$(extract_issue_from_pr "$PL_PR_BRANCH" "$PL_PR_TITLE" "$PL_PR_BODY")
  if [ -z "$PL_ISSUE" ]; then
    # Allow chore PRs from gardener/planner/predictor to merge without issue number
    if [[ "$PL_PR_BRANCH" =~ ^chore/(gardener|planner|predictor)- ]]; then
      PL_ISSUE=0
    else
      continue
    fi
  fi

  PL_CI_STATE=$(ci_commit_status "$PL_PR_SHA") || true

  # Non-code PRs may have no CI — treat as passed
  if ! ci_passed "$PL_CI_STATE" && ! ci_required_for_pr "$PL_PR_NUM"; then
    PL_CI_STATE="success"
  fi

  if ! ci_passed "$PL_CI_STATE"; then
    continue
  fi

  # Check for approval (head-aware live review — #1089: a reopened PR has
  # every review marked stale, including the one pinned to the current head)
  PL_REVIEWS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls/${PL_PR_NUM}/reviews") || true
  PL_HAS_APPROVE=$(pr_live_review_count "$PL_REVIEWS" "$PL_PR_SHA" "APPROVED")

  if [ "${PL_HAS_APPROVE:-0}" -gt 0 ]; then
    # Check if issue is assigned to this agent — only merge own PRs
    if [ "$PL_ISSUE" -gt 0 ]; then
      PR_ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/issues/${PL_ISSUE}") || true
      PR_ISSUE_ASSIGNEE=$(echo "$PR_ISSUE_JSON" | jq -r '.assignee.login // ""') || true
      if [ -n "$PR_ISSUE_ASSIGNEE" ] && [ "$PR_ISSUE_ASSIGNEE" != "$BOT_USER" ]; then
        log "PR #${PL_PR_NUM} (issue #${PL_ISSUE}) assigned to ${PR_ISSUE_ASSIGNEE} — skipping merge (not mine)"
        continue
      fi
    fi
    PL_TDM_RC=0
    try_direct_merge "$PL_PR_NUM" "$PL_ISSUE" "$PL_PR_SHA" || PL_TDM_RC=$?
    if [ "$PL_TDM_RC" -eq 0 ]; then
      PL_MERGED_ANY=true
    elif [ "$PL_TDM_RC" -eq 2 ]; then
      : # merge-blocked and already escalated — no retry, no fallback (#1090)
    fi
    # Direct merge failed (rc 1) — will fall through to post-lock dev-agent fallback
  fi
done

if [ "$PL_MERGED_ANY" = true ]; then
  log "pre-lock: merged PR(s) successfully — exiting"
  exit 0
fi
log "pre-lock: no PRs merged, checking agent lock"

# --- Check if dev-agent already running (PID lockfile) ---
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "agent running (PID ${LOCK_PID})"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi

# --- Fetch origin refs before any stale branch checks ---
git fetch origin --prune 2>/dev/null || true

# --- Memory guard ---
memory_guard 2000

# =============================================================================
# Return 0 when a dev-agent process for this issue is already alive.
#
# Two dev-agent sessions ran on issue #1067 at the same time, each with its
# own claude process, each holding a llama slot with ~136k of context, and
# neither produced a branch (issue #1070). The lock file and the remote
# branch are both checked below, but a session that has started and not yet
# written either one is invisible to those checks. The process table is not.
_dev_agent_running() {
  local issue="$1"
  pgrep -f "dev-agent\.sh ${issue}\$" >/dev/null 2>&1
}

# PRIORITY 1: orphaned in-progress issues
# =============================================================================
log "checking for in-progress issues"

ORPHANS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=in-progress&limit=10&type=issues")

ORPHAN_COUNT=$(echo "$ORPHANS_JSON" | jq 'length')
BLOCKED_BY_INPROGRESS=false
OTHER_AGENT_INPROGRESS=false
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  ISSUE_NUM=$(echo "$ORPHANS_JSON" | jq -r '.[0].number')

  # Staleness check: if no assignee, no open PR, and no agent lock, the issue is stale
  OPEN_PR=false
  if curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -e --arg branch "fix/issue-${ISSUE_NUM}" \
    '.[] | select(.head.ref == $branch)' >/dev/null 2>&1; then
    OPEN_PR=true
  fi

  # Skip issues owned by non-dev agents (bug-report, vision, prediction, etc.)
  # See issue #608: dev-poll must only touch issues it could actually claim.
  issue_labels=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${ISSUE_NUM}" | jq -r '[.labels[].name] | join(",")')
  if ! issue_is_dev_claimable "$issue_labels"; then
    log "issue #${ISSUE_NUM} has non-dev label(s) [${issue_labels}] — skipping (owned by another agent)"
    BLOCKED_BY_INPROGRESS=false
    OTHER_AGENT_INPROGRESS=true
  fi

  # Check if issue has an assignee — only block on issues assigned to this agent
  assignee=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" "${API}/issues/${ISSUE_NUM}" | jq -r '.assignee.login // ""')
  if [ -n "$assignee" ]; then
    if [ "$assignee" = "$BOT_USER" ]; then
      # Check if my PR has review feedback to address before exiting
      HAS_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/pulls?state=open&limit=20" | \
        jq -r --arg branch "fix/issue-${ISSUE_NUM}" \
        '.[] | select(.head.ref == $branch) | .number' | head -1) || true

      if [ -n "$HAS_PR" ]; then
        # Check for REQUEST_CHANGES review feedback (head-aware — #1089)
        HAS_PR_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${API}/pulls/${HAS_PR}" | jq -r '.head.sha // empty') || true
        REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${API}/pulls/${HAS_PR}/reviews") || true
        HAS_CHANGES=$(pr_live_review_count "$REVIEWS_JSON" "$HAS_PR_SHA" "REQUEST_CHANGES")

        if [ "${HAS_CHANGES:-0}" -gt 0 ]; then
          log "issue #${ISSUE_NUM} has review feedback — spawning agent"
          ("${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1) &
          log "started dev-agent PID $! for issue #${ISSUE_NUM} (review fix)"
          BLOCKED_BY_INPROGRESS=true
        else
          log "issue #${ISSUE_NUM} assigned to me — my thread is busy"
          BLOCKED_BY_INPROGRESS=true
        fi
      else
        # No open PR — check if a thread is actually alive (lock file or remote branch)
        LOCK_FILE="/tmp/dev-impl-summary-${PROJECT_NAME}-${ISSUE_NUM}.txt"
        REMOTE_BRANCH_EXISTS=$(git ls-remote --exit-code origin "fix/issue-${ISSUE_NUM}" >/dev/null 2>&1 && echo yes || echo no)

        if [ -f "$LOCK_FILE" ] || [ "$REMOTE_BRANCH_EXISTS" = "yes" ]; then
          log "issue #${ISSUE_NUM} assigned to me — my thread is busy (lock=$([ -f "$LOCK_FILE" ] && echo y || echo n) remote_branch=$REMOTE_BRANCH_EXISTS)"
          BLOCKED_BY_INPROGRESS=true
        else
          if _dev_agent_running "$ISSUE_NUM"; then
            log "issue #${ISSUE_NUM} already has a live dev-agent — not starting a second (#1070)"
          else
            log "issue #${ISSUE_NUM} self-assigned but orphaned (no lock, no branch, no PR) — recovering"
            nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
            log "started dev-agent PID $! for issue #${ISSUE_NUM} (post-crash recovery)"
          fi
          BLOCKED_BY_INPROGRESS=true
        fi
      fi
    else
      log "issue #${ISSUE_NUM} assigned to ${assignee} — their thread, not blocking"
      OTHER_AGENT_INPROGRESS=true
      # Issue assigned to another agent — skip stale checks but fall through to backlog
    fi
  fi

  # Only proceed with in-progress checks if not blocked by this agent's own work
  if [ "$BLOCKED_BY_INPROGRESS" = false ] && [ "$OTHER_AGENT_INPROGRESS" = false ]; then
    # Check for dev-agent lock file (agent may be running in another container)
    LOCK_FILE="/tmp/dev-impl-summary-${PROJECT_NAME}-${ISSUE_NUM}.txt"
    if [ -f "$LOCK_FILE" ]; then
      log "issue #${ISSUE_NUM} has agent lock file — trusting active work"
      BLOCKED_BY_INPROGRESS=true
    fi

    if [ "$OPEN_PR" = false ] && [ "$BLOCKED_BY_INPROGRESS" = false ]; then
      # Grace period: skip if in-progress label was added <60s ago (issue #471)
      if in_progress_recently_added "$ISSUE_NUM" 60; then
        log "issue #${ISSUE_NUM} in-progress label added <60s ago — skipping stale detection (grace period)"
        BLOCKED_BY_INPROGRESS=true
      else
        handle_stale_in_progress "$ISSUE_NUM"
        BLOCKED_BY_INPROGRESS=true
      fi
    fi

    # Check if there's already an open PR for this issue
    if [ "$BLOCKED_BY_INPROGRESS" = false ]; then
      HAS_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/pulls?state=open&limit=20" | \
        jq -r --arg branch "fix/issue-${ISSUE_NUM}" \
        '.[] | select(.head.ref == $branch) | .number' | head -1) || true

      if [ -n "$HAS_PR" ]; then
        # Check if branch is stale (behind primary branch)
        BRANCH="fix/issue-${ISSUE_NUM}"
        AHEAD=$(git rev-list --count "origin/${BRANCH}..origin/${PRIMARY_BRANCH}" 2>/dev/null || echo "0")
        if [ "$AHEAD" -gt 0 ]; then
          log "issue #${ISSUE_NUM} PR #${HAS_PR} is $AHEAD commits behind ${PRIMARY_BRANCH} — abandoning stale PR"
          # Close the PR via API
          curl -sf -X PATCH \
            -H "Authorization: token ${FORGE_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/pulls/${HAS_PR}" \
            -d '{"state":"closed"}' >/dev/null 2>&1 || true
          # Delete the branch via git push
          git -C "${PROJECT_REPO_ROOT:-}" push origin --delete "${BRANCH}" 2>/dev/null || true
          # Reset to fresh start on primary branch
          git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
          git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH}" 2>/dev/null || true
          BLOCKED_BY_INPROGRESS=true
        fi

        # Only process PR if not abandoned (stale branch check above)
        if [ "$BLOCKED_BY_INPROGRESS" = false ]; then
          PR_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
            "${API}/pulls/${HAS_PR}" | jq -r '.head.sha') || true
          CI_STATE=$(ci_commit_status "$PR_SHA") || true

          # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
          if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$HAS_PR"; then
            CI_STATE="success"
            log "PR #${HAS_PR} has no code files — treating CI as passed"
          fi

          # Check formal reviews (single fetch to avoid race window;
          # head-aware live reviews — #1089)
          REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
            "${API}/pulls/${HAS_PR}/reviews") || true
          HAS_APPROVE=$(pr_live_review_count "$REVIEWS_JSON" "$PR_SHA" "APPROVED")
          HAS_CHANGES=$(pr_live_review_count "$REVIEWS_JSON" "$PR_SHA" "REQUEST_CHANGES")

          if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
            IP_TDM_RC=0
            try_direct_merge "$HAS_PR" "$ISSUE_NUM" "$PR_SHA" || IP_TDM_RC=$?
            if [ "$IP_TDM_RC" -eq 0 ]; then
              BLOCKED_BY_INPROGRESS=true
            elif [ "$IP_TDM_RC" -eq 2 ]; then
              # Merge-blocked and escalated — no retry, no dev-agent. The
              # issue is now "blocked"-labeled, so the queue is not held (#1090).
              :
            else
              # Direct merge failed (conflicts?) — fall back to dev-agent
              log "falling back to dev-agent for PR #${HAS_PR} merge"
              ("${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1) &
              log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
              BLOCKED_BY_INPROGRESS=true
            fi

          # Do NOT gate REQUEST_CHANGES on ci_passed: act immediately even if CI is
          # pending/unknown. Definitive CI failure is handled by the elif below.
          elif [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
            # Check if issue is assigned to this agent — skip if assigned to another bot
            ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
              "${API}/issues/${ISSUE_NUM}") || true
            assignee=$(echo "$ISSUE_JSON" | jq -r '.assignee.login // ""') || true
            if [ -n "$assignee" ] && [ "$assignee" != "$BOT_USER" ]; then
              log "issue #${ISSUE_NUM} PR #${HAS_PR} REQUEST_CHANGES but assigned to ${assignee} — skipping"
              # Don't block — fall through to backlog
              BLOCKED_BY_INPROGRESS=false
            else
              log "issue #${ISSUE_NUM} PR #${HAS_PR} has REQUEST_CHANGES — spawning agent"
              ("${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1) &
              log "started dev-agent PID $! for issue #${ISSUE_NUM} (review fix)"
              BLOCKED_BY_INPROGRESS=true
            fi

          elif ci_failed "$CI_STATE"; then
            if handle_ci_exhaustion "$HAS_PR" "$ISSUE_NUM" "check_only"; then
              # Fall through to backlog scan instead of exit
              :
            else
              # Increment at actual launch time (not on guard-hit paths)
              if handle_ci_exhaustion "$HAS_PR" "$ISSUE_NUM"; then
                BLOCKED_BY_INPROGRESS=true  # exhausted between check and launch
              else
                log "issue #${ISSUE_NUM} PR #${HAS_PR} CI failed — spawning agent to fix (attempt ${CI_FIX_ATTEMPTS}/3)"
                ("${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1) &
                log "started dev-agent PID $! for issue #${ISSUE_NUM} (CI fix)"
                BLOCKED_BY_INPROGRESS=true
              fi
            fi

          else
            if ci_passed "$CI_STATE"; then
              # CI green + zero live reviews = no actionable next step —
              # escalate instead of holding this thread forever (#1089).
              # escalate_wedged_pr drops the in-progress label, so the next
              # poll no longer blocks on this issue.
              log "issue #${ISSUE_NUM} has open PR #${HAS_PR} (CI: ${CI_STATE}, no live review) — escalating instead of waiting (#1089)"
              escalate_wedged_pr "$ISSUE_NUM" "$HAS_PR" "$PR_SHA"
            fi
            log "issue #${ISSUE_NUM} has open PR #${HAS_PR} (CI: ${CI_STATE}, waiting)"
            BLOCKED_BY_INPROGRESS=true
          fi
        fi
      else
        # Check assignee before adopting orphaned issue
        ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${API}/issues/${ISSUE_NUM}") || true
        ASSIGNEE=$(echo "$ISSUE_JSON" | jq -r '.assignee.login // ""') || true

        if [ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != "$BOT_USER" ]; then
          log "issue #${ISSUE_NUM} assigned to ${ASSIGNEE} — skipping (not orphaned)"
          # Remove in-progress label since this agent isn't working on it
          IP_ID=$(_ilc_in_progress_id)
          curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
            "${API}/issues/${ISSUE_NUM}/labels/${IP_ID}" >/dev/null 2>&1 || true
          # Don't block — fall through to backlog
        else
          if _dev_agent_running "$ISSUE_NUM"; then
            log "issue #${ISSUE_NUM} already has a live dev-agent — not starting a second (#1070)"
          else
            log "recovering orphaned issue #${ISSUE_NUM} (no PR found, assigned to ${BOT_USER:-unassigned})"
            ("${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1) &
            log "started dev-agent PID $! for issue #${ISSUE_NUM} (recovery)"
          fi
          BLOCKED_BY_INPROGRESS=true
        fi
      fi
    fi
  fi

  # If blocked by in-progress work, exit now
  if [ "$BLOCKED_BY_INPROGRESS" = true ]; then
    exit 0
  fi
fi

# =============================================================================
# PRIORITY 1.5: any open PR with REQUEST_CHANGES or CI failure (stuck PRs)
# =============================================================================
log "checking for stuck PRs"
OPEN_PRS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

for i in $(seq 0 $(($(echo "$OPEN_PRS" | jq 'length') - 1))); do
  PR_NUM=$(echo "$OPEN_PRS" | jq -r ".[$i].number")
  PR_BRANCH=$(echo "$OPEN_PRS" | jq -r ".[$i].head.ref")
  PR_SHA=$(echo "$OPEN_PRS" | jq -r ".[$i].head.sha")
  PR_TITLE=$(echo "$OPEN_PRS" | jq -r ".[$i].title")
  PR_BODY=$(echo "$OPEN_PRS" | jq -r ".[$i].body // \"\"")

  STUCK_ISSUE=$(extract_issue_from_pr "$PR_BRANCH" "$PR_TITLE" "$PR_BODY")
  if [ -z "$STUCK_ISSUE" ]; then
    # Allow chore PRs from gardener/planner/predictor to merge without issue number
    if [[ "$PR_BRANCH" =~ ^chore/(gardener|planner|predictor)- ]]; then
      STUCK_ISSUE=0
    else
      log "PR #${PR_NUM} has no issue ref — cannot spawn dev-agent, skipping"
      continue
    fi
  fi

  CI_STATE=$(ci_commit_status "$PR_SHA") || true

  # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
  if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$PR_NUM"; then
    CI_STATE="success"
    log "PR #${PR_NUM} has no code files — treating CI as passed"
  fi

  # Single fetch to avoid race window between review checks
  # (head-aware live reviews — #1089)
  REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls/${PR_NUM}/reviews") || true
  HAS_CHANGES=$(pr_live_review_count "$REVIEWS_JSON" "$PR_SHA" "REQUEST_CHANGES")
  HAS_APPROVE=$(pr_live_review_count "$REVIEWS_JSON" "$PR_SHA" "APPROVED")

  # Merge directly if approved + CI green (no Claude needed — single API call)
  if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
    STUCK_TDM_RC=0
    try_direct_merge "$PR_NUM" "$STUCK_ISSUE" "$PR_SHA" || STUCK_TDM_RC=$?
    if [ "$STUCK_TDM_RC" -eq 0 ]; then
      exit 0
    elif [ "$STUCK_TDM_RC" -eq 2 ]; then
      # merge-blocked and already escalated — no retry, no fallback (#1090)
      continue
    fi
    # Direct merge failed — dev-agent fallback requires a real issue number
    if [ "$STUCK_ISSUE" -eq 0 ]; then
      log "PR #${PR_NUM} direct merge failed — no issue ref for dev-agent, skipping"
      continue
    fi
    # Direct merge failed (conflicts?) — fall back to dev-agent
    log "falling back to dev-agent for PR #${PR_NUM} merge"
    ("${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1) &
    log "started dev-agent PID $! for stuck PR #${PR_NUM} (agent-merge)"
    exit 0
  fi

  # Chore PRs without issue ref can only be direct-merged — skip dev-agent paths
  if [ "$STUCK_ISSUE" -eq 0 ]; then
    continue
  fi

  # Stuck: REQUEST_CHANGES or CI failure -> spawn agent
  if [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
    # Check if issue is assigned to this agent — skip if assigned to another bot
    ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${STUCK_ISSUE}") || true
    assignee=$(echo "$ISSUE_JSON" | jq -r '.assignee.login // ""') || true
    if [ -n "$assignee" ] && [ "$assignee" != "$BOT_USER" ]; then
      log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) REQUEST_CHANGES but assigned to ${assignee} — skipping"
      continue  # skip this PR, check next stuck PR or fall through to backlog
    fi
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) has REQUEST_CHANGES — fixing first"
    ("${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1) &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  elif ci_failed "$CI_STATE"; then
    if handle_ci_exhaustion "$PR_NUM" "$STUCK_ISSUE" "check_only"; then
      continue  # skip this PR, check next stuck PR or fall through to backlog
    fi
    # Increment at actual launch time (not on guard-hit paths)
    if handle_ci_exhaustion "$PR_NUM" "$STUCK_ISSUE"; then
      continue  # exhausted between check and launch
    fi
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) CI failed — fixing (attempt ${CI_FIX_ATTEMPTS}/3)"
    ("${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1) &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  fi
done

# =============================================================================
# PRIORITY 2: find ready backlog issues (pull system)
#
# Two-tier pickup: priority+backlog issues first (FIFO), then plain backlog
# issues (FIFO). The "priority" label is added alongside "backlog", not instead.
# =============================================================================
log "scanning backlog for ready issues"

# Ensure the priority label exists on this repo
ensure_priority_label >/dev/null 2>&1 || true

# Tier 1: issues with both "priority" and "backlog" labels
PRIORITY_BACKLOG_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=priority,backlog&limit=20&type=issues&sort=oldest") || true
PRIORITY_BACKLOG_JSON="${PRIORITY_BACKLOG_JSON:-[]}"

# Tier 2: all "backlog" issues (includes priority ones — deduplicated below)
ALL_BACKLOG_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=backlog&limit=20&type=issues&sort=oldest")

# Combine: priority issues first, then remaining backlog issues (deduped)
BACKLOG_JSON=$(jq -n \
  --argjson pri "$PRIORITY_BACKLOG_JSON" \
  --argjson all "$ALL_BACKLOG_JSON" \
  '($pri | map(.number)) as $pnums | $pri + [$all[] | select(.number as $n | $pnums | map(. == $n) | any | not)]')

BACKLOG_COUNT=$(echo "$BACKLOG_JSON" | jq 'length')
if [ "$BACKLOG_COUNT" -eq 0 ]; then
  log "no backlog issues"
  exit 0
fi

PRIORITY_COUNT=$(echo "$PRIORITY_BACKLOG_JSON" | jq 'length')
log "found ${BACKLOG_COUNT} backlog issues (${PRIORITY_COUNT} priority)"

# Check each for readiness
READY_ISSUE=""
READY_PR_FOR_INCREMENT=""
WAITING_PRS=""
for i in $(seq 0 $((BACKLOG_COUNT - 1))); do
  ISSUE_NUM=$(echo "$BACKLOG_JSON" | jq -r ".[$i].number")
  ISSUE_BODY=$(echo "$BACKLOG_JSON" | jq -r ".[$i].body // \"\"")

  # Check assignee before claiming — skip if assigned to another bot
  ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${ISSUE_NUM}") || true
  ASSIGNEE=$(echo "$ISSUE_JSON" | jq -r '.assignee.login // ""') || true
  if [ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != "$BOT_USER" ]; then
    log "  #${ISSUE_NUM} assigned to ${ASSIGNEE} — skipping"
    continue
  fi

  # Guard: skip issues that are not claimable right now.
  # formula/dismissed/unreviewed: handled by other tracks, not dev-agent.
  # waiting-on-compute: readiness flag — work is dispatched and waiting on an
  # external run; a person or formula removes the label when the run lands (#1072).
  ISSUE_LABELS=$(echo "$BACKLOG_JSON" | jq -r ".[$i].labels[].name" 2>/dev/null) || true
  SKIP_LABEL=$(echo "$ISSUE_LABELS" | grep -oE '^(formula|prediction/dismissed|prediction/unreviewed|waiting-on-compute)$' | head -1) || true
  if [ -n "$SKIP_LABEL" ]; then
    log "issue #${ISSUE_NUM} has '${SKIP_LABEL}' label — skipping in backlog scan"
    continue
  fi

  if ! issue_is_ready "$ISSUE_NUM" "$ISSUE_BODY"; then
    continue
  fi

  # Check if there's already an open PR for this issue that needs attention
  EXISTING_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" --arg num "#${ISSUE_NUM}" \
    '.[] | select((.head.ref == $branch) or (.title | contains($num))) | .number' | head -1) || true

  if [ -n "$EXISTING_PR" ]; then
    # Check if branch is stale (behind primary branch)
    BRANCH="fix/issue-${ISSUE_NUM}"
    AHEAD=$(git rev-list --count "origin/${BRANCH}..origin/${PRIMARY_BRANCH}" 2>/dev/null || echo "0")
    if [ "$AHEAD" -gt 0 ]; then
      log "issue #${ISSUE_NUM} PR #${EXISTING_PR} is $AHEAD commits behind ${PRIMARY_BRANCH} — abandoning stale PR"
      # Close the PR via API
      curl -sf -X PATCH \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${EXISTING_PR}" \
        -d '{"state":"closed"}' >/dev/null 2>&1 || true
      # Delete the branch via git push
      git -C "${PROJECT_REPO_ROOT:-}" push origin --delete "${BRANCH}" 2>/dev/null || true
      # Reset to fresh start on primary branch
      git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
      git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH}" 2>/dev/null || true
      # Continue to find another ready issue
      continue
    fi

    PR_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(ci_commit_status "$PR_SHA") || true

    # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
    if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$EXISTING_PR"; then
      CI_STATE="success"
      log "PR #${EXISTING_PR} has no code files — treating CI as passed"
    fi

    # Single fetch to avoid race window between review checks
    # (head-aware live reviews — #1089)
    REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}/reviews") || true
    HAS_APPROVE=$(pr_live_review_count "$REVIEWS_JSON" "$PR_SHA" "APPROVED")
    HAS_CHANGES=$(pr_live_review_count "$REVIEWS_JSON" "$PR_SHA" "REQUEST_CHANGES")

    if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      BL_TDM_RC=0
      try_direct_merge "$EXISTING_PR" "$ISSUE_NUM" "$PR_SHA" || BL_TDM_RC=$?
      if [ "$BL_TDM_RC" -eq 0 ]; then
        exit 0
      elif [ "$BL_TDM_RC" -eq 2 ]; then
        # merge-blocked and already escalated — no retry, no fallback
        # (#1090); keep scanning the backlog
        continue
      fi
      # Direct merge failed (conflicts?) — fall back to dev-agent
      log "falling back to dev-agent for PR #${EXISTING_PR} merge"
      ("${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1) &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
      exit 0

    elif [ "${HAS_CHANGES:-0}" -gt 0 ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} has REQUEST_CHANGES — picking up"
      READY_ISSUE="$ISSUE_NUM"
      break

    elif ci_failed "$CI_STATE"; then
      if handle_ci_exhaustion "$EXISTING_PR" "$ISSUE_NUM" "check_only"; then
        # Don't add to WAITING_PRS — escalated PRs should not block new work
        continue
      fi
      log "#${ISSUE_NUM} PR #${EXISTING_PR} CI failed — picking up (attempt $((CI_FIX_ATTEMPTS+1))/3)"
      READY_ISSUE="$ISSUE_NUM"
      READY_PR_FOR_INCREMENT="$EXISTING_PR"
      break

    else
      if ci_passed "$CI_STATE"; then
        # CI green + zero live reviews = no actionable next step. Holding the
        # queue here would block every other backlog issue indefinitely
        # (#1089) — escalate instead.
        log "#${ISSUE_NUM} PR #${EXISTING_PR} CI passed (${CI_STATE}) but no live review — no actionable next step; escalating instead of holding the queue (#1089)"
        escalate_wedged_pr "$ISSUE_NUM" "$EXISTING_PR" "$PR_SHA"
        continue
      fi
      log "#${ISSUE_NUM} PR #${EXISTING_PR} exists (CI: ${CI_STATE}, waiting)"
      WAITING_PRS="${WAITING_PRS:-}${WAITING_PRS:+, }#${EXISTING_PR}"
      continue
    fi
  fi

  READY_ISSUE="$ISSUE_NUM"
  log "#${ISSUE_NUM} is READY (all deps merged, no existing PR)"
  break
done

# Single-threaded per project: if any issue has an open PR waiting for review/CI,
# don't start new work — let the pipeline drain first
# But only block on PRs assigned to this agent (per-agent logic from #358)
if [ -n "$READY_ISSUE" ] && [ -n "${WAITING_PRS:-}" ]; then
  # Filter to only this agent's waiting PRs
  MY_WAITING_PRS=""
  for pr_num in $(echo "$WAITING_PRS" | tr ',' ' '); do
    pr_num="${pr_num#\#}"  # Remove leading #
    # Check if this PR's issue is assigned to this agent
    pr_info=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${pr_num}" 2>/dev/null) || true
    pr_branch=$(echo "$pr_info" | jq -r '.head.ref') || true
    issue_num=$(echo "$pr_branch" | grep -oP '(?<=fix/issue-)\d+' || true)
    if [ -z "$issue_num" ]; then
      continue
    fi
    issue_assignee=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${issue_num}" 2>/dev/null | jq -r '.assignee.login // ""') || true
    if [ -n "$issue_assignee" ] && [ "$issue_assignee" = "$BOT_USER" ]; then
      MY_WAITING_PRS="${MY_WAITING_PRS:-}${MY_WAITING_PRS:+, }#${pr_num}"
    fi
  done

  if [ -n "$MY_WAITING_PRS" ]; then
    log "holding #${READY_ISSUE} — waiting for my open PR(s) to land first: ${MY_WAITING_PRS}"
    exit 0
  fi
  log "other agents' PRs waiting: ${WAITING_PRS} — proceeding with #${READY_ISSUE}"
fi

if [ -z "$READY_ISSUE" ]; then
  log "no ready issues (all blocked by unmerged deps)"
  exit 0
fi

# =============================================================================
# LAUNCH: start dev-agent for the ready issue
# =============================================================================
# Deferred CI fix increment — only now that we're certain we are launching.
if [ -n "${READY_PR_FOR_INCREMENT:-}" ]; then
  if handle_ci_exhaustion "$READY_PR_FOR_INCREMENT" "$READY_ISSUE"; then
    # exhausted (another poller incremented between scan and launch) — bail out
    exit 0
  fi
fi

log "launching dev-agent for #${READY_ISSUE}"
("${SCRIPT_DIR}/dev-agent.sh" "$READY_ISSUE" >> "$LOGFILE" 2>&1) &
log "started dev-agent PID $! for issue #${READY_ISSUE}"
