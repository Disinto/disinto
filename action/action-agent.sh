#!/usr/bin/env bash
# =============================================================================
# action-agent.sh — Synchronous action agent: SDK + shared libraries
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Usage: ./action-agent.sh <issue-number> [project.toml]
#
# Flow:
#   1. Preflight: issue_check_deps(), memory guard, concurrency lock
#   2. Parse model from YAML front matter in issue body (custom model selection)
#   3. Worktree: worktree_create() for action isolation
#   4. Load formula from issue body
#   5. Build prompt: formula + prior non-bot comments (resume context)
#   6. agent_run(worktree, prompt) → Claude executes action, may push
#   7. If pushed: pr_walk_to_merge() from lib/pr-lifecycle.sh
#   8. Cleanup: worktree_cleanup(), issue_close()
#
# Action-specific (stays in runner):
#   - YAML front matter parsing (model selection)
#   - Bot username filtering for prior comments
#   - Lifetime watchdog (MAX_LIFETIME=8h wall-clock cap)
#   - Child process cleanup (docker compose, background jobs)
#
# From shared libraries:
#   - Issue lifecycle: lib/issue-lifecycle.sh
#   - Worktree: lib/worktree.sh
#   - PR lifecycle: lib/pr-lifecycle.sh
#   - Agent SDK: lib/agent-sdk.sh
#
# Log: action/action-poll-{project}.log
# =============================================================================
set -euo pipefail

ISSUE="${1:?Usage: action-agent.sh <issue-number> [project.toml]}"
export PROJECT_TOML="${2:-${PROJECT_TOML:-}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# Use action-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_ACTION_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/issue-lifecycle.sh
source "$FACTORY_ROOT/lib/issue-lifecycle.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"
# shellcheck source=../lib/pr-lifecycle.sh
source "$FACTORY_ROOT/lib/pr-lifecycle.sh"

BRANCH="action/issue-${ISSUE}"
WORKTREE="/tmp/action-${ISSUE}-$(date +%s)"
LOCKFILE="/tmp/action-agent-${ISSUE}.lock"
LOGFILE="${DISINTO_LOG_DIR}/action/action-poll-${PROJECT_NAME:-default}.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/action-session-${PROJECT_NAME:-default}-${ISSUE}.sid"
MAX_LIFETIME="${ACTION_MAX_LIFETIME:-28800}"  # 8h default wall-clock cap
SESSION_START_EPOCH=$(date +%s)

log() {
  printf '[%s] action#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

# --- Concurrency lock (per issue) ---
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "SKIP: action-agent already running for #${ISSUE} (PID ${LOCK_PID})"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

cleanup() {
  local exit_code=$?
  # Kill lifetime watchdog if running
  if [ -n "${LIFETIME_WATCHDOG_PID:-}" ] && kill -0 "$LIFETIME_WATCHDOG_PID" 2>/dev/null; then
    kill "$LIFETIME_WATCHDOG_PID" 2>/dev/null || true
    wait "$LIFETIME_WATCHDOG_PID" 2>/dev/null || true
  fi
  rm -f "$LOCKFILE"
  # Kill any remaining child processes spawned during the run
  local children
  children=$(jobs -p 2>/dev/null) || true
  if [ -n "$children" ]; then
    # shellcheck disable=SC2086  # intentional word splitting
    kill $children 2>/dev/null || true
    # shellcheck disable=SC2086
    wait $children 2>/dev/null || true
  fi
  # Best-effort docker cleanup for containers started during this action
  (cd "${WORKTREE}" 2>/dev/null && docker compose down 2>/dev/null) || true
  # Preserve worktree on crash for debugging; clean up on success
  if [ "$exit_code" -ne 0 ]; then
    worktree_preserve "$WORKTREE" "crashed (exit=$exit_code)"
  else
    worktree_cleanup "$WORKTREE"
  fi
  rm -f "$SID_FILE"
}
trap cleanup EXIT

# --- Memory guard ---
memory_guard 2000

# --- Fetch issue ---
log "fetching issue #${ISSUE}"
ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues/${ISSUE}") || true

if [ -z "$ISSUE_JSON" ] || ! printf '%s' "$ISSUE_JSON" | jq -e '.id' >/dev/null 2>&1; then
  log "ERROR: failed to fetch issue #${ISSUE}"
  exit 1
fi

ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_STATE=$(printf '%s' "$ISSUE_JSON" | jq -r '.state')

if [ "$ISSUE_STATE" != "open" ]; then
  log "SKIP: issue #${ISSUE} is ${ISSUE_STATE}"
  exit 0
fi

log "Issue: ${ISSUE_TITLE}"

# --- Dependency check (shared library) ---
if ! issue_check_deps "$ISSUE"; then
  log "SKIP: issue #${ISSUE} blocked by: ${_ISSUE_BLOCKED_BY[*]}"
  exit 0
fi

# --- Extract model from YAML front matter (if present) ---
YAML_MODEL=$(printf '%s' "$ISSUE_BODY" | \
  sed -n '/^---$/,/^---$/p' | grep '^model:' | awk '{print $2}' | tr -d '"' || true)
if [ -n "$YAML_MODEL" ]; then
  export CLAUDE_MODEL="$YAML_MODEL"
  log "model from front matter: ${YAML_MODEL}"
fi

# --- Resolve bot username(s) for comment filtering ---
_bot_login=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API%%/repos*}/user" | jq -r '.login // empty' 2>/dev/null || true)

# Build list: token owner + any extra names from FORGE_BOT_USERNAMES (comma-separated)
_bot_logins="${_bot_login}"
if [ -n "${FORGE_BOT_USERNAMES:-}" ]; then
  _bot_logins="${_bot_logins:+${_bot_logins},}${FORGE_BOT_USERNAMES}"
fi

# --- Fetch existing comments (resume context, excluding bot comments) ---
COMMENTS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues/${ISSUE}/comments?limit=50") || true

PRIOR_COMMENTS=""
if [ -n "$COMMENTS_JSON" ] && [ "$COMMENTS_JSON" != "null" ] && [ "$COMMENTS_JSON" != "[]" ]; then
  PRIOR_COMMENTS=$(printf '%s' "$COMMENTS_JSON" | \
    jq -r --arg bots "$_bot_logins" \
      '($bots | split(",") | map(select(. != ""))) as $bl |
       .[] | select(.user.login as $u | $bl | index($u) | not) |
       "[\(.user.login) at \(.created_at[:19])]\n\(.body)\n---"' 2>/dev/null || true)
fi

# --- Determine git remote ---
cd "${PROJECT_REPO_ROOT}"
_forge_host=$(echo "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
FORGE_REMOTE=$(git remote -v | awk -v host="$_forge_host" '$2 ~ host && /\(push\)/ {print $1; exit}')
FORGE_REMOTE="${FORGE_REMOTE:-origin}"
export FORGE_REMOTE

# --- Create isolated worktree ---
log "creating worktree: ${WORKTREE}"
git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
if ! worktree_create "$WORKTREE" "$BRANCH"; then
  log "ERROR: worktree creation failed"
  exit 1
fi
log "worktree ready: ${WORKTREE}"

# --- Build prompt ---
PRIOR_SECTION=""
if [ -n "$PRIOR_COMMENTS" ]; then
  PRIOR_SECTION="## Prior comments (resume context)

${PRIOR_COMMENTS}

"
fi

GIT_INSTRUCTIONS=$(build_phase_protocol_prompt "$BRANCH" "$FORGE_REMOTE")

PROMPT="You are an action agent. Your job is to execute the action formula
in the issue below.

## Issue #${ISSUE}: ${ISSUE_TITLE}

${ISSUE_BODY}

${PRIOR_SECTION}## Instructions

1. Read the action formula steps in the issue body carefully.

2. Execute each step in order using your Bash tool and any other tools available.

3. Post progress as comments on issue #${ISSUE} after significant steps:
   curl -sf -X POST \\
     -H \"Authorization: token \${FORGE_TOKEN}\" \\
     -H 'Content-Type: application/json' \\
     \"${FORGE_API}/issues/${ISSUE}/comments\" \\
     -d \"{\\\"body\\\": \\\"your comment here\\\"}\"

4. If a step requires human input or approval, post a comment explaining what
   is needed and stop — the orchestrator will block the issue.

### Path A: If this action produces code changes (e.g. config updates, baselines):
   - You are already in an isolated worktree at: ${WORKTREE}
   - You are on branch: ${BRANCH}
   - Make your changes, commit, and push: git push ${FORGE_REMOTE} ${BRANCH}
   - **IMPORTANT:** The worktree is destroyed after completion. Push all
     results before finishing — unpushed work will be lost.

### Path B: If this action produces no code changes (investigation, report):
   - Post results as a comment on issue #${ISSUE}.
   - **IMPORTANT:** The worktree is destroyed after completion. Copy any
     files you need to persistent paths before finishing.

5. Environment variables available in your bash sessions:
   FORGE_TOKEN, FORGE_API, FORGE_REPO, FORGE_WEB, PROJECT_NAME
   (all sourced from ${FACTORY_ROOT}/.env)

### CRITICAL: Never embed secrets in issue bodies, comments, or PR descriptions
   - NEVER put API keys, tokens, passwords, or private keys in issue text or comments.
   - Always reference secrets via env var names (e.g. \\\$BASE_RPC_URL, \\\${FORGE_TOKEN}).
   - If a formula step needs a secret, read it from .env or the environment at runtime.
   - Before posting any comment, verify it contains no credentials, hex keys > 32 chars,
     or URLs with embedded API keys.

If the prior comments above show work already completed, resume from where it
left off.

${GIT_INSTRUCTIONS}"

# --- Wall-clock lifetime watchdog (background) ---
# Caps total run time independently of claude -p timeout. When the cap is
# hit the watchdog kills the main process, which triggers cleanup via trap.
_lifetime_watchdog() {
  local remaining=$(( MAX_LIFETIME - ($(date +%s) - SESSION_START_EPOCH) ))
  [ "$remaining" -le 0 ] && remaining=1
  sleep "$remaining"
  local hours=$(( MAX_LIFETIME / 3600 ))
  log "MAX_LIFETIME (${hours}h) reached — killing agent"
  # Post summary comment on issue
  local body="Action agent killed: wall-clock lifetime cap (${hours}h) reached."
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${FORGE_API}/issues/${ISSUE}/comments" \
    -d "{\"body\": \"${body}\"}" >/dev/null 2>&1 || true
  kill $$ 2>/dev/null || true
}
_lifetime_watchdog &
LIFETIME_WATCHDOG_PID=$!

# --- Run agent ---
log "running agent (worktree: ${WORKTREE})"
agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

# --- Detect if branch was pushed (Path A vs Path B) ---
PUSHED=false
# Check if remote branch exists
git fetch "${FORGE_REMOTE}" "$BRANCH" 2>/dev/null || true
if git rev-parse --verify "${FORGE_REMOTE}/${BRANCH}" >/dev/null 2>&1; then
  PUSHED=true
fi
# Fallback: check local commits ahead of base
if [ "$PUSHED" = false ]; then
  if git -C "$WORKTREE" log "${FORGE_REMOTE}/${PRIMARY_BRANCH}..${BRANCH}" --oneline 2>/dev/null | grep -q .; then
    PUSHED=true
  fi
fi

if [ "$PUSHED" = true ]; then
  # --- Path A: code changes pushed — create PR and walk to merge ---
  log "branch pushed — creating PR"
  PR_NUMBER=""
  PR_NUMBER=$(pr_create "$BRANCH" "action: ${ISSUE_TITLE}" \
    "Closes #${ISSUE}

Automated action execution by action-agent.") || true

  if [ -n "$PR_NUMBER" ]; then
    log "walking PR #${PR_NUMBER} to merge"
    pr_walk_to_merge "$PR_NUMBER" "$_AGENT_SESSION_ID" "$WORKTREE" || true

    case "${_PR_WALK_EXIT_REASON:-}" in
      merged)
        log "PR #${PR_NUMBER} merged — closing issue"
        issue_close "$ISSUE"
        ;;
      *)
        log "PR #${PR_NUMBER} not merged (reason: ${_PR_WALK_EXIT_REASON:-unknown})"
        issue_block "$ISSUE" "pr_not_merged: ${_PR_WALK_EXIT_REASON:-unknown}"
        ;;
    esac
  else
    log "ERROR: failed to create PR"
    issue_block "$ISSUE" "pr_creation_failed"
  fi
else
  # --- Path B: no code changes — close issue directly ---
  log "no branch pushed — closing issue (Path B)"
  issue_close "$ISSUE"
fi

log "action-agent finished for issue #${ISSUE}"
