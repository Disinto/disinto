#!/usr/bin/env bash
# agent-sdk.sh — Shared SDK for synchronous Claude agent invocations
#
# Provides agent_run(): one-shot `claude -p` with session persistence.
# Source this from any agent script after defining:
#   SID_FILE  — path to persist session ID (e.g. /tmp/dev-session-proj-123.sid)
#   LOGFILE   — path for log output
#   log()     — logging function
#
# Usage:
#   source "$(dirname "$0")/../lib/agent-sdk.sh"
#   agent_run [--resume SESSION_ID] [--worktree DIR] PROMPT
#
# After each call, _AGENT_SESSION_ID holds the session ID (also saved to SID_FILE).
# Recover a previous session on startup:
#   if [ -f "$SID_FILE" ]; then _AGENT_SESSION_ID=$(cat "$SID_FILE"); fi

set -euo pipefail

_AGENT_SESSION_ID=""

# agent_run — synchronous Claude invocation (one-shot claude -p)
# Usage: agent_run [--resume SESSION_ID] [--worktree DIR] PROMPT
# Sets: _AGENT_SESSION_ID (updated each call, persisted to SID_FILE)
agent_run() {
  local resume_id="" worktree_dir=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --resume) shift; resume_id="${1:-}"; shift ;;
      --worktree) shift; worktree_dir="${1:-}"; shift ;;
      *) shift ;;
    esac
  done
  local prompt="${1:-}"

  local -a args=(-p "$prompt" --output-format json --dangerously-skip-permissions --max-turns 200)
  [ -n "$resume_id" ] && args+=(--resume "$resume_id")
  [ -n "${CLAUDE_MODEL:-}" ] && args+=(--model "$CLAUDE_MODEL")

  local run_dir="${worktree_dir:-$(pwd)}"
  local output
  log "agent_run: starting (resume=${resume_id:-(new)}, dir=${run_dir})"
  output=$(cd "$run_dir" && timeout "${CLAUDE_TIMEOUT:-7200}" claude "${args[@]}" 2>>"$LOGFILE") || true

  # Extract and persist session_id
  local new_sid
  new_sid=$(printf '%s' "$output" | jq -r '.session_id // empty' 2>/dev/null) || true
  if [ -n "$new_sid" ]; then
    _AGENT_SESSION_ID="$new_sid"
    printf '%s' "$new_sid" > "$SID_FILE"
    log "agent_run: session_id=${new_sid:0:12}..."
  fi
}
