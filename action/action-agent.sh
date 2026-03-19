#!/usr/bin/env bash
# action-agent.sh — Autonomous action agent: tmux + Claude + action formula
#
# Usage: ./action-agent.sh <issue-number> [project.toml]
#
# Lifecycle:
#   1. Fetch issue body (action formula) + existing comments
#   2. Create tmux session: action-{issue_num} with interactive claude
#   3. Inject initial prompt: formula + comments + instructions
#   4. Claude executes formula steps, posts progress comments, closes issue
#   5. For human input: Claude asks via Matrix; reply injected via matrix_listener
#   6. Monitor session until Claude exits or idle timeout reached
#
# Session:  action-{issue_num} (tmux)
# Log:      action/action-poll-{project}.log

set -euo pipefail

ISSUE="${1:?Usage: action-agent.sh <issue-number> [project.toml]}"
export PROJECT_TOML="${2:-${PROJECT_TOML:-}}"

source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/agent-session.sh"
SESSION_NAME="action-${ISSUE}"
LOCKFILE="/tmp/action-agent-${ISSUE}.lock"
LOGFILE="${FACTORY_ROOT}/action/action-poll-${PROJECT_NAME:-harb}.log"
THREAD_FILE="/tmp/action-thread-${ISSUE}"
IDLE_TIMEOUT="${ACTION_IDLE_TIMEOUT:-14400}"  # 4h default

log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
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
  rm -f "$LOCKFILE"
  agent_kill_session "$SESSION_NAME"
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
ISSUE_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${CODEBERG_API}/issues/${ISSUE}") || true

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

# --- Fetch existing comments (resume context) ---
COMMENTS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${CODEBERG_API}/issues/${ISSUE}/comments?limit=50") || true

PRIOR_COMMENTS=""
if [ -n "$COMMENTS_JSON" ] && [ "$COMMENTS_JSON" != "null" ] && [ "$COMMENTS_JSON" != "[]" ]; then
  PRIOR_COMMENTS=$(printf '%s' "$COMMENTS_JSON" | \
    jq -r '.[] | "[\(.user.login) at \(.created_at[:19])]\n\(.body)\n---"' 2>/dev/null || true)
fi

# --- Create Matrix thread for this issue ---
ISSUE_URL="${CODEBERG_WEB}/issues/${ISSUE}"
_thread_id=$(matrix_send_ctx "action" \
  "⚡ Action #${ISSUE}: ${ISSUE_TITLE} — ${ISSUE_URL}" \
  "⚡ <a href='${ISSUE_URL}'>Action #${ISSUE}</a>: ${ISSUE_TITLE}") || true

THREAD_ID=""
if [ -n "${_thread_id:-}" ]; then
  printf '%s' "$_thread_id" > "$THREAD_FILE"
  THREAD_ID="$_thread_id"
  # Register thread root in map for listener dispatch (column 4 = issue number)
  printf '%s\t%s\t%s\t%s\n' "$_thread_id" "action" "$(date +%s)" "${ISSUE}" \
    >> "${MATRIX_THREAD_MAP:-/tmp/matrix-thread-map}" 2>/dev/null || true
fi

# --- Build initial prompt ---
PRIOR_SECTION=""
if [ -n "$PRIOR_COMMENTS" ]; then
  PRIOR_SECTION="## Prior comments (resume context)

${PRIOR_COMMENTS}

"
fi

THREAD_HINT=""
if [ -n "$THREAD_ID" ]; then
  THREAD_HINT="
   The Matrix thread ID for this issue is: ${THREAD_ID}
   Use it as the thread_event_id when sending Matrix messages so replies
   are routed back to this session."
fi

INITIAL_PROMPT="You are an action agent. Your job is to execute the action formula
in the issue below and then close the issue.

## Issue #${ISSUE}: ${ISSUE_TITLE}

${ISSUE_BODY}

${PRIOR_SECTION}## Instructions

1. Read the action formula steps in the issue body carefully.

2. Execute each step in order using your Bash tool and any other tools available.

3. Post progress as comments on issue #${ISSUE} after significant steps:
   curl -sf -X POST \\
     -H \"Authorization: token \${CODEBERG_TOKEN}\" \\
     -H 'Content-Type: application/json' \\
     \"${CODEBERG_API}/issues/${ISSUE}/comments\" \\
     -d \"{\\\"body\\\": \\\"your comment here\\\"}\"

4. If a step requires human input or approval, send a Matrix message explaining
   what you need, then wait. A human will reply and the reply will be injected
   into this session automatically.${THREAD_HINT}

5. When all steps are complete, close issue #${ISSUE} with a summary:
   curl -sf -X PATCH \\
     -H \"Authorization: token \${CODEBERG_TOKEN}\" \\
     -H 'Content-Type: application/json' \\
     \"${CODEBERG_API}/issues/${ISSUE}\" \\
     -d '{\"state\": \"closed\"}'

6. Environment variables available in your bash sessions:
   CODEBERG_TOKEN, CODEBERG_API, CODEBERG_REPO, CODEBERG_WEB, PROJECT_NAME
   (all sourced from ${FACTORY_ROOT}/.env)

**Important**: You do NOT need to create PRs or write a phase file. Just execute
the formula steps, post comments, and close the issue when done. If the prior
comments above show work already completed, resume from where it left off."

# --- Create tmux session ---
log "creating tmux session: ${SESSION_NAME}"
if ! create_agent_session "${SESSION_NAME}" "${FACTORY_ROOT}"; then
  log "ERROR: failed to create tmux session"
  exit 1
fi

# --- Inject initial prompt ---
inject_formula "${SESSION_NAME}" "${INITIAL_PROMPT}"
log "initial prompt injected into session"

matrix_send "action" "⚡ #${ISSUE}: session started — ${ISSUE_TITLE}" \
  "${THREAD_ID}" 2>/dev/null || true

# --- Monitor session until Claude exits or idle timeout ---
log "monitoring session: ${SESSION_NAME} (idle_timeout=${IDLE_TIMEOUT}s)"
ELAPSED=0
POLL_INTERVAL=30

while tmux has-session -t "${SESSION_NAME}" 2>/dev/null; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  if [ "$ELAPSED" -ge "$IDLE_TIMEOUT" ]; then
    log "idle timeout (${IDLE_TIMEOUT}s) — killing session for issue #${ISSUE}"
    matrix_send "action" "⚠️ #${ISSUE}: session idle for $((IDLE_TIMEOUT / 3600))h — killed" \
      "${THREAD_ID}" 2>/dev/null || true
    agent_kill_session "${SESSION_NAME}"
    break
  fi
done

log "action-agent finished for issue #${ISSUE}"
