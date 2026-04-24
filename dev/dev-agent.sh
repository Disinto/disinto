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
source "$(dirname "$0")/../lib/mirrors.sh"
source "$(dirname "$0")/../lib/agent-sdk.sh"
source "$(dirname "$0")/../lib/formula-session.sh"

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

LOGFILE="${DISINTO_LOG_DIR}/dev/dev-agent.log"

log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

status() {
  printf '[%s] dev-agent #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" > "$STATUSFILE"
  log "$*"
}

# =============================================================================
# CLEANUP
# =============================================================================
CLAIMED=false
PR_NUMBER=""

cleanup() {
  rm -f "$LOCKFILE" "$STATUSFILE"
  # If we claimed the issue but never created a PR, release it
  if [ "$CLAIMED" = true ] && [ -z "$PR_NUMBER" ]; then
    log "cleanup: releasing issue (no PR created)"
    issue_release "$ISSUE"
  fi
}
trap cleanup EXIT

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
  # Ensure repo is in clean state
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

### Next steps
1. Run \`git log --oneline -5\` and \`git status\` to understand current state.
2. Read AGENTS.md for project conventions.
3. Address any pending review comments or CI failures.
4. Commit and push to \`${BRANCH}\`.

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
- Already done: {\"status\":\"already_done\",\"reason\":\"where\"}

${PUSH_INSTRUCTIONS}"
fi

# =============================================================================
# IMPLEMENT
# =============================================================================
status "running implementation"
echo '{"status":"ready"}' > "$PREFLIGHT_RESULT"

if [ -n "$_AGENT_SESSION_ID" ]; then
  agent_run --resume "$_AGENT_SESSION_ID" --worktree "$WORKTREE" "$INITIAL_PROMPT"
else
  agent_run --worktree "$WORKTREE" "$INITIAL_PROMPT"
fi

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

    case "$REFUSAL_STATUS" in
      unmet_dependency)
        BLOCKED_BY_MSG=$(printf '%s' "$REFUSAL_JSON" | jq -r '.blocked_by // "unknown"')
        SUGGESTION=$(printf '%s' "$REFUSAL_JSON" | jq -r '.suggestion // empty')
        COMMENT_BODY="### Blocked by unmet dependency

${BLOCKED_BY_MSG}"
        [ -n "$SUGGESTION" ] && [ "$SUGGESTION" != "null" ] && \
          COMMENT_BODY="${COMMENT_BODY}

**Suggestion:** Work on #${SUGGESTION} first."
        issue_post_refusal "$ISSUE" "🚧" "Unmet dependency" "$COMMENT_BODY"
        issue_release "$ISSUE"
        CLAIMED=false
        ;;
      too_large)
        REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
        issue_post_refusal "$ISSUE" "📏" "Too large for single session" \
          "### Why this can't be implemented as-is

${REASON}

### Next steps
A maintainer should split this issue or add more detail to the spec."
        # Add underspecified label, remove backlog + in-progress
        UNDERSPEC_ID=$(forge_api GET "/labels" 2>/dev/null \
          | jq -r '.[] | select(.name == "underspecified") | .id' 2>/dev/null || true)
        if [ -n "$UNDERSPEC_ID" ]; then
          forge_api POST "/issues/${ISSUE}/labels" \
            -d "{\"labels\":[${UNDERSPEC_ID}]}" >/dev/null 2>&1 || true
        fi
        BACKLOG_ID=$(forge_api GET "/labels" 2>/dev/null \
          | jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)
        if [ -n "$BACKLOG_ID" ]; then
          forge_api DELETE "/issues/${ISSUE}/labels/${BACKLOG_ID}" >/dev/null 2>&1 || true
        fi
        IP_ID=$(forge_api GET "/labels" 2>/dev/null \
          | jq -r '.[] | select(.name == "in-progress") | .id' 2>/dev/null || true)
        if [ -n "$IP_ID" ]; then
          forge_api DELETE "/issues/${ISSUE}/labels/${IP_ID}" >/dev/null 2>&1 || true
        fi
        CLAIMED=false
        ;;
      already_done)
        REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
        issue_post_refusal "$ISSUE" "✅" "Already implemented" \
          "### Existing implementation

${REASON}

Closing as already implemented."
        issue_close "$ISSUE"
        CLAIMED=false
        ;;
    esac
    worktree_cleanup "$WORKTREE"
    rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE"
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

  issue_block "$ISSUE" "no_push" "Claude did not push branch ${BRANCH}"
  CLAIMED=false
  worktree_cleanup "$WORKTREE"
  rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE"
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

if [ "$rc" -eq 0 ]; then
  # Merged successfully
  log "PR #${PR_NUMBER} merged"
  issue_close "$ISSUE"

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
  rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE"
  CLAIMED=false
else
  # Exhausted or unrecoverable failure
  log "PR walk failed: ${_PR_WALK_EXIT_REASON:-unknown}"
  issue_block "$ISSUE" "${_PR_WALK_EXIT_REASON:-agent_failed}"

  # Capture files changed for journal entry (after agent work)
  FILES_CHANGED=$(git -C "$WORKTREE" diff "${FORGE_REMOTE}/${PRIMARY_BRANCH}..HEAD" --name-only 2>/dev/null | tr '\n' ',' | sed 's/,$//') || FILES_CHANGED=""

  # Write journal entry post-session (before cleanup)
  outcome="blocked_${_PR_WALK_EXIT_REASON:-agent_failed}"
  profile_write_journal "$ISSUE" "$ISSUE_TITLE" "$outcome" "$FILES_CHANGED" || true

  # Cleanup on failure: preserve remote branch and PR for debugging, clean up local worktree
  # Remote state (PR and branch) stays open for inspection of CI logs and review comments
  worktree_cleanup "$WORKTREE"
  rm -f "$SID_FILE" "$IMPL_SUMMARY_FILE"
  CLAIMED=false
fi

log "dev-agent finished for issue #${ISSUE}"
