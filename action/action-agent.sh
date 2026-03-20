#!/usr/bin/env bash
# action-agent.sh — Autonomous action agent: tmux + Claude + action formula
#
# Usage: ./action-agent.sh <issue-number> [project.toml]
#
# Lifecycle:
#   1. Fetch issue body (action formula) + existing comments
#   2. Create tmux session: action-{issue_num} with interactive claude
#   3. Inject initial prompt: formula + comments + phase protocol instructions
#   4. Monitor phase file via monitor_phase_loop (shared with dev-agent)
#   Path A (git output): Claude pushes → handler creates PR → CI poll → review
#     injection → merge → cleanup (same loop as dev-agent via phase-handler.sh)
#   Path B (no git output): Claude posts results → PHASE:done → cleanup
#   5. For human input: Claude asks via Matrix; reply injected via matrix_listener
#   6. Cleanup on terminal phase: kill tmux, docker compose down, remove temp files
#
# Session:  action-{issue_num} (tmux)
# Log:      action/action-poll-{project}.log

set -euo pipefail

ISSUE="${1:?Usage: action-agent.sh <issue-number> [project.toml]}"
export PROJECT_TOML="${2:-${PROJECT_TOML:-}}"

source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/agent-session.sh"
source "$(dirname "$0")/../lib/formula-session.sh"
# shellcheck source=../dev/phase-handler.sh
source "$(dirname "$0")/../dev/phase-handler.sh"
SESSION_NAME="action-${ISSUE}"
LOCKFILE="/tmp/action-agent-${ISSUE}.lock"
LOGFILE="${FACTORY_ROOT}/action/action-poll-${PROJECT_NAME:-harb}.log"
THREAD_FILE="/tmp/action-thread-${ISSUE}"
IDLE_TIMEOUT="${ACTION_IDLE_TIMEOUT:-14400}"  # 4h default

# --- Phase handler globals (agent-specific; defaults in phase-handler.sh) ---
# shellcheck disable=SC2034  # used by phase-handler.sh
API="${CODEBERG_API}"
BRANCH="action/issue-${ISSUE}"
# shellcheck disable=SC2034  # used by phase-handler.sh
WORKTREE="${PROJECT_REPO_ROOT}"
PHASE_FILE="/tmp/action-session-${PROJECT_NAME:-harb}-${ISSUE}.phase"
IMPL_SUMMARY_FILE="/tmp/action-impl-summary-${PROJECT_NAME:-harb}-${ISSUE}.txt"
PREFLIGHT_RESULT="/tmp/action-preflight-${ISSUE}.json"
SCRATCH_FILE="/tmp/action-${ISSUE}-scratch.md"

log() {
  printf '[%s] action#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

notify() {
  local thread_id=""
  [ -f "${THREAD_FILE:-}" ] && thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
  matrix_send "action" "⚡ #${ISSUE}: $*" "${thread_id}" 2>/dev/null || true
}

notify_ctx() {
  local plain="$1" html="$2" thread_id=""
  [ -f "${THREAD_FILE:-}" ] && thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
  if [ -n "$thread_id" ]; then
    matrix_send_ctx "action" "⚡ #${ISSUE}: ${plain}" "⚡ #${ISSUE}: ${html}" "${thread_id}" 2>/dev/null || true
  else
    matrix_send "action" "⚡ #${ISSUE}: ${plain}" "" "${ISSUE}" 2>/dev/null || true
  fi
}

status() {
  log "$*"
}

# --- Action-specific stubs for phase-handler.sh ---
cleanup_worktree() { :; }  # action agent uses PROJECT_REPO_ROOT directly — no separate git worktree to remove
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
  rm -f "$LOCKFILE"
  agent_kill_session "$SESSION_NAME"
  # Best-effort docker cleanup for containers started during this action
  (cd "${PROJECT_REPO_ROOT}" 2>/dev/null && docker compose down 2>/dev/null) || true
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

# --- Extract model from YAML front matter (if present) ---
YAML_MODEL=$(printf '%s' "$ISSUE_BODY" | \
  sed -n '/^---$/,/^---$/p' | grep '^model:' | awk '{print $2}' | tr -d '"' || true)
if [ -n "$YAML_MODEL" ]; then
  export CLAUDE_MODEL="$YAML_MODEL"
  log "model from front matter: ${YAML_MODEL}"
fi

# --- Resolve bot username(s) for comment filtering ---
_bot_login=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${CODEBERG_API%%/repos*}/user" | jq -r '.login // empty' 2>/dev/null || true)

# Build list: token owner + any extra names from CODEBERG_BOT_USERNAMES (comma-separated)
_bot_logins="${_bot_login}"
if [ -n "${CODEBERG_BOT_USERNAMES:-}" ]; then
  _bot_logins="${_bot_logins:+${_bot_logins},}${CODEBERG_BOT_USERNAMES}"
fi

# --- Fetch existing comments (resume context, excluding bot comments) ---
COMMENTS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${CODEBERG_API}/issues/${ISSUE}/comments?limit=50") || true

PRIOR_COMMENTS=""
if [ -n "$COMMENTS_JSON" ] && [ "$COMMENTS_JSON" != "null" ] && [ "$COMMENTS_JSON" != "[]" ]; then
  PRIOR_COMMENTS=$(printf '%s' "$COMMENTS_JSON" | \
    jq -r --arg bots "$_bot_logins" \
      '($bots | split(",") | map(select(. != ""))) as $bl |
       .[] | select(.user.login as $u | $bl | index($u) | not) |
       "[\(.user.login) at \(.created_at[:19])]\n\(.body)\n---"' 2>/dev/null || true)
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
  # Export for on-stop-matrix.sh hook (streams Claude output to thread)
  export MATRIX_THREAD_ID="$_thread_id"
  # Register thread root in map for listener dispatch (column 4 = issue number)
  printf '%s\t%s\t%s\t%s\n' "$_thread_id" "action" "$(date +%s)" "${ISSUE}" \
    >> "${MATRIX_THREAD_MAP:-/tmp/matrix-thread-map}" 2>/dev/null || true
fi

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

THREAD_HINT=""
if [ -n "$THREAD_ID" ]; then
  THREAD_HINT="
   The Matrix thread ID for this issue is: ${THREAD_ID}
   Use it as the thread_event_id when sending Matrix messages so replies
   are routed back to this session."
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
     -H \"Authorization: token \${CODEBERG_TOKEN}\" \\
     -H 'Content-Type: application/json' \\
     \"${CODEBERG_API}/issues/${ISSUE}/comments\" \\
     -d \"{\\\"body\\\": \\\"your comment here\\\"}\"

4. If a step requires human input or approval, send a Matrix message explaining
   what you need, then wait. A human will reply and the reply will be injected
   into this session automatically.${THREAD_HINT}

### Path A: If this action produces code changes (e.g. config updates, baselines):
   - Work in the project repo: cd ${PROJECT_REPO_ROOT}
   - Create and switch to branch: git checkout -b ${BRANCH}
   - Make your changes, commit, and push: git push origin ${BRANCH}
   - Follow the phase protocol below — the orchestrator handles PR creation,
     CI monitoring, and review injection.

### Path B: If this action produces no code changes (investigation, report):
   - Post results as a comment on issue #${ISSUE}.
   - Close the issue:
     curl -sf -X PATCH \\
       -H \"Authorization: token \${CODEBERG_TOKEN}\" \\
       -H 'Content-Type: application/json' \\
       \"${CODEBERG_API}/issues/${ISSUE}\" \\
       -d '{\"state\": \"closed\"}'
   - Signal completion: echo \"PHASE:done\" > \"${PHASE_FILE}\"

5. Environment variables available in your bash sessions:
   CODEBERG_TOKEN, CODEBERG_API, CODEBERG_REPO, CODEBERG_WEB, PROJECT_NAME
   (all sourced from ${FACTORY_ROOT}/.env)

If the prior comments above show work already completed, resume from where it
left off.

${SCRATCH_INSTRUCTION}

${PHASE_PROTOCOL_INSTRUCTIONS}"

# --- Create tmux session ---
log "creating tmux session: ${SESSION_NAME}"
if ! create_agent_session "${SESSION_NAME}" "${FACTORY_ROOT}" "${PHASE_FILE}"; then
  log "ERROR: failed to create tmux session"
  exit 1
fi

# --- Inject initial prompt ---
inject_formula "${SESSION_NAME}" "${INITIAL_PROMPT}"
log "initial prompt injected into session"

matrix_send "action" "⚡ #${ISSUE}: session started — ${ISSUE_TITLE}" \
  "${THREAD_ID}" 2>/dev/null || true

# --- Monitor phase loop (shared with dev-agent) ---
status "monitoring phase: ${PHASE_FILE} (action agent)"
monitor_phase_loop "$PHASE_FILE" "$IDLE_TIMEOUT" _on_phase_change "$SESSION_NAME"

# Handle exit reason from monitor_phase_loop
case "${_MONITOR_LOOP_EXIT:-}" in
  idle_timeout)
    notify_ctx \
      "session idle for $((IDLE_TIMEOUT / 3600))h — killed" \
      "session idle for $((IDLE_TIMEOUT / 3600))h — killed"
    # Escalate to supervisor (idle_prompt already escalated via _on_phase_change callback)
    echo "{\"issue\":${ISSUE},\"pr\":${PR_NUMBER:-0},\"reason\":\"idle_timeout\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      >> "${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl"
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$THREAD_FILE" "$SCRATCH_FILE"
    ;;
  idle_prompt)
    # Notification + escalation already handled by _on_phase_change(PHASE:failed) callback
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$THREAD_FILE" "$SCRATCH_FILE"
    ;;
  done)
    # Belt-and-suspenders: callback handles primary cleanup,
    # but ensure sentinel files are removed if callback was interrupted
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$IMPL_SUMMARY_FILE" "$THREAD_FILE" "$SCRATCH_FILE"
    ;;
esac

log "action-agent finished for issue #${ISSUE}"
