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
# Call agent_recover_session() on startup to restore a previous session.

set -euo pipefail

_AGENT_SESSION_ID=""

# agent_recover_session — restore session_id from SID_FILE if it exists.
# Call this before agent_run --resume to enable session continuity.
agent_recover_session() {
  if [ -f "$SID_FILE" ]; then
    _AGENT_SESSION_ID=$(cat "$SID_FILE")
    log "agent_recover_session: ${_AGENT_SESSION_ID:0:12}..."
  fi
}

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

  # Save output for diagnostics (no_push, crashes)
  _AGENT_LAST_OUTPUT="$output"
  local diag_file="${DISINTO_LOG_DIR:-/tmp}/dev/agent-run-last.json"
  printf '%s' "$output" > "$diag_file" 2>/dev/null || true

  # Nudge: if the model stopped without pushing, resume with encouragement.
  # Some models emit end_turn prematurely when confused. A nudge often unsticks them.
  if [ -n "$_AGENT_SESSION_ID" ]; then
    local has_changes
    has_changes=$(cd "$run_dir" && git status --porcelain 2>/dev/null | head -1) || true
    local has_pushed
    has_pushed=$(cd "$run_dir" && git log --oneline "${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH:-main}..HEAD" 2>/dev/null | head -1) || true
    if [ -z "$has_pushed" ]; then
      local nudge="You stopped but did not push any code. "
      if [ -n "$has_changes" ]; then
        nudge+="You have uncommitted changes. Commit them and push."
      else
        nudge+="Complete the implementation, commit, and push your branch."
      fi
      log "agent_run: nudging (no push detected)"
      output=$(cd "$run_dir" && timeout "${CLAUDE_TIMEOUT:-7200}" claude -p "$nudge" --resume "$_AGENT_SESSION_ID" --output-format json --dangerously-skip-permissions --max-turns 50 ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} 2>>"$LOGFILE") || true
      new_sid=$(printf '%s' "$output" | jq -r '.session_id // empty' 2>/dev/null) || true
      if [ -n "$new_sid" ]; then
        _AGENT_SESSION_ID="$new_sid"
        printf '%s' "$new_sid" > "$SID_FILE"
      fi
      printf '%s' "$output" > "$diag_file" 2>/dev/null || true
      _AGENT_LAST_OUTPUT="$output"
    fi
  fi
}
