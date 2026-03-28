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

# Auto-pull factory code to pick up merged fixes before any logic runs
git -C "$FACTORY_ROOT" pull --ff-only origin main 2>/dev/null || true

# --- Config ---
ISSUE="${1:?Usage: dev-agent.sh <issue-number>}"
REPO_ROOT="${PROJECT_REPO_ROOT}"

LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-default}.lock"
STATUSFILE="/tmp/dev-agent-status-${PROJECT_NAME:-default}"
BRANCH="fix/issue-${ISSUE}"
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
_bot_login=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API%%/repos*}/user" | jq -r '.login // empty' 2>/dev/null || true)
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
issue_claim "$ISSUE"
CLAIMED=true

# =============================================================================
# CHECK FOR EXISTING PR (recovery mode)
# =============================================================================
RECOVERY_MODE=false

# Check issue body for explicit PR reference
BODY_PR=$(printf '%s' "$ISSUE_BODY_ORIGINAL" | grep -oP 'Existing PR:\s*#\K[0-9]+' | head -1) || true
if [ -n "$BODY_PR" ]; then
  PR_CHECK=$(forge_api GET "/pulls/${BODY_PR}") || true
  PR_CHECK_STATE=$(printf '%s' "$PR_CHECK" | jq -r '.state')
  if [ "$PR_CHECK_STATE" = "open" ]; then
    PR_NUMBER="$BODY_PR"
    BRANCH=$(printf '%s' "$PR_CHECK" | jq -r '.head.ref')
    log "found existing PR #${PR_NUMBER} on branch ${BRANCH} (from issue body)"
  fi
fi

# Priority 1: match by branch name
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(pr_find_by_branch "$BRANCH") || true
  [ -n "$PR_NUMBER" ] && log "found existing PR #${PR_NUMBER} (from branch match)"
fi

# Priority 2: match "Fixes #NNN" in PR body
if [ -z "$PR_NUMBER" ]; then
  FOUND_PR=$(forge_api GET "/pulls?state=open&limit=20" | \
    jq -r --arg issue "ixes #${ISSUE}\\b" \
    '.[] | select(.body | test($issue; "i")) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$FOUND_PR" ]; then
    PR_NUMBER=$(printf '%s' "$FOUND_PR" | awk '{print $1}')
    BRANCH=$(printf '%s' "$FOUND_PR" | awk '{print $2}')
    log "found existing PR #${PR_NUMBER} on branch ${BRANCH} (from body match)"
  fi
fi

# Priority 3: check closed PRs for prior art
PRIOR_ART_DIFF=""
if [ -z "$PR_NUMBER" ]; then
  CLOSED_PR=$(forge_api GET "/pulls?state=closed&limit=30" | \
    jq -r --arg issue "#${ISSUE}" \
    '.[] | select(.merged != true) | select((.title | contains($issue)) or (.body // "" | test("ixes " + $issue + "\\b"; "i"))) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$CLOSED_PR" ]; then
    CLOSED_PR_NUM=$(printf '%s' "$CLOSED_PR" | awk '{print $1}')
    log "found closed (unmerged) PR #${CLOSED_PR_NUM} as prior art"
    PRIOR_ART_DIFF=$(forge_api GET "/pulls/${CLOSED_PR_NUM}.diff" 2>/dev/null \
      | head -500) || true
  fi
fi

if [ -n "$PR_NUMBER" ]; then
  RECOVERY_MODE=true
  log "RECOVERY MODE: adopting PR #${PR_NUMBER} on branch ${BRANCH}"
fi

# Recover session_id from .sid file (crash recovery)
agent_recover_session

# =============================================================================
# WORKTREE SETUP
# =============================================================================
status "setting up worktree"
cd "$REPO_ROOT"

# Determine forge remote by matching FORGE_URL host against git remotes
_forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
FORGE_REMOTE=$(git remote -v | awk -v host="$_forge_host" '$2 ~ host && /\(push\)/ {print $1; exit}')
FORGE_REMOTE="${FORGE_REMOTE:-origin}"
export FORGE_REMOTE
log "forge remote: ${FORGE_REMOTE}"

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
  CLAIMED=false
fi

log "dev-agent finished for issue #${ISSUE}"
