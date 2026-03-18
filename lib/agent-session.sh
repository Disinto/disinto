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

# Create a tmux session running Claude in the given workdir.
# Returns 0 if session is ready, 1 otherwise.
create_agent_session() {
  local session="$1"
  local workdir="${2:-.}"
  tmux new-session -d -s "$session" -c "$workdir" \
    "claude --dangerously-skip-permissions" 2>/dev/null
  sleep 1
  tmux has-session -t "$session" 2>/dev/null || return 1
  agent_wait_for_claude_ready "$session" 120 || return 1
  return 0
}

# Inject a prompt/formula into a session (alias for agent_inject_into_session).
inject_formula() {
  agent_inject_into_session "$@"
}

# Monitor a phase file, calling a callback on changes and handling idle timeout.
# Sets _MONITOR_LOOP_EXIT to the exit reason (idle_timeout, done, failed, break).
# Args: phase_file idle_timeout_secs callback_fn
monitor_phase_loop() {
  local phase_file="$1"
  local idle_timeout="$2"
  local callback="$3"
  local poll_interval="${PHASE_POLL_INTERVAL:-10}"
  local last_mtime=0
  local idle_elapsed=0

  while true; do
    sleep "$poll_interval"
    idle_elapsed=$(( idle_elapsed + poll_interval ))

    # Session health check
    if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
      local current_phase
      current_phase=$(head -1 "$phase_file" 2>/dev/null | tr -d '[:space:]' || true)
      case "$current_phase" in
        PHASE:done|PHASE:failed|PHASE:merged)
          ;; # terminal — fall through to phase handler
        *)
          # Call callback with "crashed" — let agent-specific code handle recovery
          if type "${callback}" &>/dev/null; then
            "$callback" "PHASE:crashed"
          fi
          # If callback didn't restart session, break
          if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
            _MONITOR_LOOP_EXIT="crashed"
            return 1
          fi
          idle_elapsed=0
          continue
          ;;
      esac
    fi

    # Check phase file for changes
    local phase_mtime
    phase_mtime=$(stat -c %Y "$phase_file" 2>/dev/null || echo 0)
    local current_phase
    current_phase=$(head -1 "$phase_file" 2>/dev/null | tr -d '[:space:]' || true)

    if [ -z "$current_phase" ] || [ "$phase_mtime" -le "$last_mtime" ]; then
      # No phase change — check idle timeout
      if [ "$idle_elapsed" -ge "$idle_timeout" ]; then
        _MONITOR_LOOP_EXIT="idle_timeout"
        agent_kill_session "${SESSION_NAME}"
        return 0
      fi
      continue
    fi

    # Phase changed
    last_mtime="$phase_mtime"
    # shellcheck disable=SC2034  # read by phase-handler.sh callback
    LAST_PHASE_MTIME="$phase_mtime"
    idle_elapsed=0

    # Terminal phases
    case "$current_phase" in
      PHASE:done|PHASE:merged)
        _MONITOR_LOOP_EXIT="done"
        if type "${callback}" &>/dev/null; then
          "$callback" "$current_phase"
        fi
        return 0
        ;;
      PHASE:failed|PHASE:needs_human)
        _MONITOR_LOOP_EXIT="$current_phase"
        if type "${callback}" &>/dev/null; then
          "$callback" "$current_phase"
        fi
        return 0
        ;;
    esac

    # Non-terminal phase — call callback
    if type "${callback}" &>/dev/null; then
      "$callback" "$current_phase"
    fi
  done
}

# Kill a tmux session gracefully (no-op if not found).
agent_kill_session() {
  local session="${1:-}"
  [ -n "$session" ] && tmux kill-session -t "$session" 2>/dev/null || true
}

# Read the current phase from a phase file, stripped of whitespace.
# Usage: read_phase [file]  — defaults to $PHASE_FILE
read_phase() {
  local file="${1:-${PHASE_FILE:-}}"
  { cat "$file" 2>/dev/null || true; } | head -1 | tr -d '[:space:]'
}
