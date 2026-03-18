#!/usr/bin/env bash
# agent-session.sh — Shared tmux + Claude interactive session helpers
#
# Source this into agent orchestrator scripts for reusable session management.
#
# Functions:
#   agent_wait_for_claude_ready SESSION_NAME [TIMEOUT_SECS]
#   agent_inject_into_session   SESSION_NAME TEXT
#   agent_kill_session          SESSION_NAME

# Wait for the Claude ❯ ready prompt in a tmux pane.
# Returns 0 if ready within TIMEOUT_SECS (default 120), 1 otherwise.
agent_wait_for_claude_ready() {
  local session="$1"
  local timeout="${2:-120}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if tmux capture-pane -t "$session" -p 2>/dev/null | grep -q '❯'; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# Paste TEXT into SESSION (waits for Claude to be ready first), then press Enter.
agent_inject_into_session() {
  local session="$1"
  local text="$2"
  local tmpfile
  agent_wait_for_claude_ready "$session" 120 || true
  tmpfile=$(mktemp /tmp/agent-inject-XXXXXX)
  printf '%s' "$text" > "$tmpfile"
  tmux load-buffer -b "agent-inject-$$" "$tmpfile"
  tmux paste-buffer -t "$session" -b "agent-inject-$$"
  sleep 0.5
  tmux send-keys -t "$session" "" Enter
  tmux delete-buffer -b "agent-inject-$$" 2>/dev/null || true
  rm -f "$tmpfile"
}

# Kill a tmux session gracefully (no-op if not found).
agent_kill_session() {
  tmux kill-session -t "$1" 2>/dev/null || true
}
