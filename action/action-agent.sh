#!/usr/bin/env bash
# action-agent.sh — Autonomous action agent: tmux + Claude + action formula
#
# Usage: ./action-agent.sh <issue-number> [project.toml]
#
# Lifecycle:
#   1. Fetch issue body (action formula) + existing comments
#   2. Create isolated git worktree: /tmp/action-{issue}-{timestamp}
#   3. Create tmux session: action-{project}-{issue_num} with interactive claude in worktree
#   4. Inject initial prompt: formula + comments + phase protocol instructions
#   5. Monitor phase file via monitor_phase_loop (shared with dev-agent)
#   Path A (git output): Claude pushes → handler creates PR → CI poll → review
#     injection → merge → cleanup (same loop as dev-agent via phase-handler.sh)
#   Path B (no git output): Claude posts results → PHASE:done → cleanup
#   6. For human input: Claude writes PHASE:escalate; human responds via vault/forge
#   7. Cleanup on terminal phase: kill children, destroy worktree, remove temp files
#
# Key principle: The runtime creates and destroys. The formula preserves.
# The formula must push results before signaling done — the worktree is nuked after.
#
# Session:  action-{project}-{issue_num} (tmux)
# Log:      action/action-poll-{project}.log

set -euo pipefail

ISSUE="${1:?Usage: action-agent.sh <issue-number> [project.toml]}"
export PROJECT_TOML="${2:-${PROJECT_TOML:-}}"

source "$(dirname "$0")/../lib/env.sh"
# Use action-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_ACTION_TOKEN:-${FORGE_TOKEN}}"
source "$(dirname "$0")/../lib/ci-helpers.sh"
source "$(dirname "$0")/../lib/agent-session.sh"
source "$(dirname "$0")/../lib/formula-session.sh"
# shellcheck source=../dev/phase-handler.sh
source "$(dirname "$0")/../dev/phase-handler.sh"
SESSION_NAME="action-${PROJECT_NAME}-${ISSUE}"
LOCKFILE="/tmp/action-agent-${ISSUE}.lock"
LOGFILE="${FACTORY_ROOT}/action/action-poll-${PROJECT_NAME:-default}.log"
IDLE_TIMEOUT="${ACTION_IDLE_TIMEOUT:-14400}"  # 4h default
MAX_LIFETIME="${ACTION_MAX_LIFETIME:-28800}" # 8h default wall-clock cap
SESSION_START_EPOCH=$(date +%s)

# --- Phase handler globals (agent-specific; defaults in phase-handler.sh) ---
# shellcheck disable=SC2034  # used by phase-handler.sh
API="${FORGE_API}"
BRANCH="action/issue-${ISSUE}"
# shellcheck disable=SC2034  # used by phase-handler.sh
WORKTREE="/tmp/action-${ISSUE}-$(date +%s)"
PHASE_FILE="/tmp/action-session-${PROJECT_NAME:-default}-${ISSUE}.phase"
IMPL_SUMMARY_FILE="/tmp/action-impl-summary-${PROJECT_NAME:-default}-${ISSUE}.txt"
PREFLIGHT_RESULT="/tmp/action-preflight-${ISSUE}.json"
SCRATCH_FILE="/tmp/action-${ISSUE}-scratch.md"

log() {
  printf '[%s] action#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

status() {
  log "$*"
}

# --- Action-specific helpers for phase-handler.sh ---
cleanup_worktree() {
  cd "${PROJECT_REPO_ROOT}" 2>/dev/null || true
  git worktree remove "$WORKTREE" --force 2>/dev/null || true
  rm -rf "$WORKTREE"
  # Clear Claude Code session history for this worktree to prevent hallucinated "already done"
  local claude_project_dir
  claude_project_dir="$HOME/.claude/projects/$(echo "$WORKTREE" | sed 's|/|-|g; s|^-||')"
  rm -rf "$claude_project_dir" 2>/dev/null || true
  log "destroyed worktree: ${WORKTREE}"
}
cleanup_labels() { :; }    # action agent doesn't use in-progress labels

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
  agent_kill_session "$SESSION_NAME"
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
  local final_phase=""
  [ -f "$PHASE_FILE" ] && final_phase=$(head -1 "$PHASE_FILE" 2>/dev/null || true)
  if [ "${final_phase:-}" = "PHASE:crashed" ] || [ "${_MONITOR_LOOP_EXIT:-}" = "crashed" ] || [ "$exit_code" -ne 0 ]; then
    log "PRESERVED crashed worktree for debugging: $WORKTREE"
  else
    cleanup_worktree
  fi
  rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$PREFLIGHT_RESULT"
}
trap cleanup EXIT

# --- Memory guard ---
AVAIL_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt 2000 ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need 2000MB)"
  exit 0
fi

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

# --- Dependency check (skip before spawning Claude) ---
DEPS=$(printf '%s' "$ISSUE_BODY" | bash "${FACTORY_ROOT}/lib/parse-deps.sh")
if [ -n "$DEPS" ]; then
  ALL_MET=true
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    DEP_STATE=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${dep}" | jq -r '.state // "open"') || DEP_STATE="open"
    if [ "$DEP_STATE" != "closed" ]; then
      log "SKIP: dependency #${dep} still open — not spawning session"
      ALL_MET=false
      break
    fi
  done <<< "$DEPS"
  if [ "$ALL_MET" = false ]; then
    rm -f "$LOCKFILE"
    exit 0
  fi
  log "all dependencies met"
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

# --- Create isolated worktree ---
log "creating worktree: ${WORKTREE}"
cd "${PROJECT_REPO_ROOT}"

# Determine which git remote corresponds to FORGE_URL
_forge_host=$(echo "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
FORGE_REMOTE=$(git remote -v | awk -v host="$_forge_host" '$2 ~ host && /\(push\)/ {print $1; exit}')
FORGE_REMOTE="${FORGE_REMOTE:-origin}"
export FORGE_REMOTE

git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
if ! git worktree add "$WORKTREE" "${FORGE_REMOTE}/${PRIMARY_BRANCH}" 2>&1; then
  log "ERROR: worktree creation failed"
  exit 1
fi
log "worktree ready: ${WORKTREE}"

# --- Read scratch file (compaction survival) ---
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# --- Build initial prompt ---
PRIOR_SECTION=""
if [ -n "$PRIOR_COMMENTS" ]; then
  PRIOR_SECTION="## Prior comments (resume context)

${PRIOR_COMMENTS}

"
fi

# Build phase protocol from shared function (Path B covered in Instructions section above)
PHASE_PROTOCOL_INSTRUCTIONS="$(build_phase_protocol_prompt "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "$BRANCH")"

# Write phase protocol to context file for compaction survival
write_compact_context "$PHASE_FILE" "$PHASE_PROTOCOL_INSTRUCTIONS"

INITIAL_PROMPT="You are an action agent. Your job is to execute the action formula
in the issue below.

## Issue #${ISSUE}: ${ISSUE_TITLE}

${ISSUE_BODY}
${SCRATCH_CONTEXT}
${PRIOR_SECTION}## Instructions

1. Read the action formula steps in the issue body carefully.

2. Execute each step in order using your Bash tool and any other tools available.

3. Post progress as comments on issue #${ISSUE} after significant steps:
   curl -sf -X POST \\
     -H \"Authorization: token \${FORGE_TOKEN}\" \\
     -H 'Content-Type: application/json' \\
     \"${FORGE_API}/issues/${ISSUE}/comments\" \\
     -d \"{\\\"body\\\": \\\"your comment here\\\"}\"

4. If a step requires human input or approval, write PHASE:escalate with a reason.
   A human will review and respond via the forge.

### Path A: If this action produces code changes (e.g. config updates, baselines):
   - You are already in an isolated worktree at: ${WORKTREE}
   - Create and switch to branch: git checkout -b ${BRANCH}
   - Make your changes, commit, and push: git push ${FORGE_REMOTE} ${BRANCH}
   - **IMPORTANT:** The worktree is destroyed after completion. Push all
     results before signaling done — unpushed work will be lost.
   - Follow the phase protocol below — the orchestrator handles PR creation,
     CI monitoring, and review injection.

### Path B: If this action produces no code changes (investigation, report):
   - Post results as a comment on issue #${ISSUE}.
   - **IMPORTANT:** The worktree is destroyed after completion. Copy any
     files you need to persistent paths before signaling done.
   - Close the issue:
     curl -sf -X PATCH \\
       -H \"Authorization: token \${FORGE_TOKEN}\" \\
       -H 'Content-Type: application/json' \\
       \"${FORGE_API}/issues/${ISSUE}\" \\
       -d '{\"state\": \"closed\"}'
   - Signal completion: echo \"PHASE:done\" > \"${PHASE_FILE}\"

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

${SCRATCH_INSTRUCTION}

${PHASE_PROTOCOL_INSTRUCTIONS}"

# --- Create tmux session ---
log "creating tmux session: ${SESSION_NAME}"
if ! create_agent_session "${SESSION_NAME}" "${WORKTREE}" "${PHASE_FILE}"; then
  log "ERROR: failed to create tmux session"
  exit 1
fi

# --- Inject initial prompt ---
inject_formula "${SESSION_NAME}" "${INITIAL_PROMPT}"
log "initial prompt injected into session"

# --- Wall-clock lifetime watchdog (background) ---
# Caps total session time independently of idle timeout.  When the cap is
# hit the watchdog kills the tmux session, posts a summary comment on the
# issue, and writes PHASE:failed so monitor_phase_loop exits.
_lifetime_watchdog() {
  local remaining=$(( MAX_LIFETIME - ($(date +%s) - SESSION_START_EPOCH) ))
  [ "$remaining" -le 0 ] && remaining=1
  sleep "$remaining"
  local hours=$(( MAX_LIFETIME / 3600 ))
  log "MAX_LIFETIME (${hours}h) reached — killing session"
  agent_kill_session "$SESSION_NAME"
  # Post summary comment on issue
  local body="Action session killed: wall-clock lifetime cap (${hours}h) reached."
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${FORGE_API}/issues/${ISSUE}/comments" \
    -d "{\"body\": \"${body}\"}" >/dev/null 2>&1 || true
  printf 'PHASE:failed\nReason: max_lifetime (%sh) reached\n' "$hours" > "$PHASE_FILE"
  # Touch phase-changed marker so monitor_phase_loop picks up immediately
  touch "/tmp/phase-changed-${SESSION_NAME}.marker"
}
_lifetime_watchdog &
LIFETIME_WATCHDOG_PID=$!

# --- Monitor phase loop (shared with dev-agent) ---
status "monitoring phase: ${PHASE_FILE} (action agent)"
monitor_phase_loop "$PHASE_FILE" "$IDLE_TIMEOUT" _on_phase_change "$SESSION_NAME"

# Handle exit reason from monitor_phase_loop
case "${_MONITOR_LOOP_EXIT:-}" in
  idle_timeout)
    # Post diagnostic comment + label blocked
    post_blocked_diagnostic "idle_timeout"
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$SCRATCH_FILE"
    ;;
  idle_prompt)
    # Notification + blocked label already handled by _on_phase_change(PHASE:failed) callback
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$SCRATCH_FILE"
    ;;
  PHASE:failed)
    # Check if this was a max_lifetime kill (phase file contains the reason)
    if grep -q 'max_lifetime' "$PHASE_FILE" 2>/dev/null; then
      post_blocked_diagnostic "max_lifetime"
    fi
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$SCRATCH_FILE"
    ;;
  done)
    # Belt-and-suspenders: callback handles primary cleanup,
    # but ensure sentinel files are removed if callback was interrupted
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$SCRATCH_FILE"
    ;;
esac

log "action-agent finished for issue #${ISSUE}"
