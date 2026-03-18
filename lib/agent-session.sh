#!/usr/bin/env bash
# lib/agent-session.sh — Reusable tmux + Claude agent runtime
#
# Source this in any agent script after lib/env.sh.
#
# Required globals (set by the caller before using functions):
#   SESSION_NAME        — tmux session name (e.g., "dev-harb-935")
#   PHASE_FILE          — path to phase file
#   LOGFILE             — path to log file
#   ISSUE               — issue/context identifier (used in log prefix)
#   STATUSFILE          — path to status file
#   THREAD_FILE         — path to Matrix thread ID file
#   WORKTREE            — agent working directory (for crash recovery)
#   PRIMARY_BRANCH      — primary git branch (for crash recovery diff)
#
# Optional globals:
#   PHASE_POLL_INTERVAL — seconds between phase polls (default: 30)
#
# Globals exported by monitor_phase_loop (readable by phase callbacks):
#   LAST_PHASE_MTIME    — mtime of the phase file when the current phase was dispatched
#   _MONITOR_LOOP_EXIT  — set on return: "idle_timeout", "crash_recovery_failed",
#                         or "callback_break"

# log — Timestamped logging to LOGFILE
# Usage: log <message>
log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "${ISSUE:-?}" "$*" >> "${LOGFILE:-/dev/null}"
}

# status — Log + write current status to STATUSFILE
# Usage: status <message>
status() {
  printf '[%s] agent #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "${ISSUE:-?}" "$*" > "${STATUSFILE:-/dev/null}"
  log "$*"
}

# notify — Send plain-text Matrix notification into the issue thread
# Usage: notify <message>
notify() {
  local thread_id=""
  [ -f "${THREAD_FILE:-}" ] && thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
  matrix_send "dev" "🔧 #${ISSUE}: $*" "${thread_id}" 2>/dev/null || true
}

# notify_ctx — Send rich Matrix notification with HTML context into the issue thread
# Falls back to plain send (registering a thread root) when no thread exists.
# Usage: notify_ctx <plain_text> <html_body>
notify_ctx() {
  local plain="$1" html="$2"
  local thread_id=""
  [ -f "${THREAD_FILE:-}" ] && thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
  if [ -n "$thread_id" ]; then
    matrix_send_ctx "dev" "🔧 #${ISSUE}: ${plain}" "🔧 #${ISSUE}: ${html}" "${thread_id}" 2>/dev/null || true
  else
    # No thread — fall back to plain send so a thread root is registered
    matrix_send "dev" "🔧 #${ISSUE}: ${plain}" "" "${ISSUE}" 2>/dev/null || true
  fi
}

# read_phase — Read current value from PHASE_FILE, stripping whitespace
# Usage: read_phase
read_phase() {
  { cat "${PHASE_FILE}" 2>/dev/null || true; } | head -1 | tr -d '[:space:]'
}

# wait_for_claude_ready — Poll SESSION_NAME tmux pane until Claude shows ❯ prompt
# Usage: wait_for_claude_ready [timeout_seconds]
# Returns: 0 if ready, 1 if timeout
wait_for_claude_ready() {
  local timeout="${1:-120}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    # Claude Code shows ❯ when ready for input
    if tmux capture-pane -t "${SESSION_NAME}" -p 2>/dev/null | grep -q '❯'; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log "WARNING: claude not ready after ${timeout}s — proceeding anyway"
  return 1
}

# inject_into_session — Paste text into the tmux session via tmux buffer
# Usage: inject_into_session <text>
inject_into_session() {
  local text="$1"
  local tmpfile
  wait_for_claude_ready 120
  tmpfile=$(mktemp /tmp/tmux-inject-XXXXXX)
  printf '%s' "$text" > "$tmpfile"
  tmux load-buffer -b "inject-${ISSUE}" "$tmpfile"
  tmux paste-buffer -t "${SESSION_NAME}" -b "inject-${ISSUE}"
  sleep 0.5
  tmux send-keys -t "${SESSION_NAME}" "" Enter
  tmux delete-buffer -b "inject-${ISSUE}" 2>/dev/null || true
  rm -f "$tmpfile"
}

# kill_tmux_session — Kill SESSION_NAME tmux session
# Usage: kill_tmux_session
kill_tmux_session() {
  tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
}

# create_agent_session — Create (or reuse) a detached tmux session running claude
# Sets SESSION_NAME to $1 and uses $2 as the working directory.
# Usage: create_agent_session <session_name> <workdir>
# Returns: 0 on success, 1 on failure
create_agent_session() {
  SESSION_NAME="${1:-${SESSION_NAME}}"
  local workdir="${2:-${WORKTREE}}"

  if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    log "reusing existing tmux session: ${SESSION_NAME}"
    return 0
  fi

  # Kill any stale entry before creating
  tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true

  tmux new-session -d -s "${SESSION_NAME}" -c "${workdir}" \
    "claude --dangerously-skip-permissions"

  if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    log "ERROR: failed to create tmux session ${SESSION_NAME}"
    return 1
  fi
  log "tmux session created: ${SESSION_NAME}"

  if ! wait_for_claude_ready 120; then
    log "ERROR: claude did not become ready in ${SESSION_NAME}"
    kill_tmux_session
    return 1
  fi
  return 0
}

# inject_formula — Send a formula/prompt into the agent session
# Usage: inject_formula <session_name> <formula_text> [context]
inject_formula() {
  SESSION_NAME="${1:-${SESSION_NAME}}"
  local formula_text="$2"
  # $3 context is available for future use by callers
  inject_into_session "$formula_text"
}

# Globals exported by monitor_phase_loop for use by phase callbacks.
# LAST_PHASE_MTIME: mtime of phase file at the time the current phase was dispatched.
# _MONITOR_LOOP_EXIT: reason monitor_phase_loop returned — check after the call.
LAST_PHASE_MTIME=0
_MONITOR_LOOP_EXIT=""

# monitor_phase_loop — Watch PHASE_FILE and dispatch phase changes to a callback
#
# Handles: phase change detection, idle timeout, and session crash recovery.
# The phase callback receives the current phase string as $1.
# Return 1 from the callback to break the loop; return 0 (or default) to continue.
#
# On idle timeout: kills the session, sets _MONITOR_LOOP_EXIT=idle_timeout, breaks.
# On crash recovery failure: sets _MONITOR_LOOP_EXIT=crash_recovery_failed, breaks.
# On callback return 1: sets _MONITOR_LOOP_EXIT=callback_break, breaks.
#
# LAST_PHASE_MTIME is updated before each callback invocation so callbacks can
# detect subsequent phase file changes (e.g., during inner polling loops).
#
# Usage: monitor_phase_loop <phase_file> <idle_timeout_secs> <phase_callback_fn>
monitor_phase_loop() {
  local phase_file="${1:-${PHASE_FILE}}"
  local idle_timeout="${2:-7200}"
  local callback_fn="${3:-}"
  local poll_interval="${PHASE_POLL_INTERVAL:-30}"
  local current_phase phase_mtime crash_diff recovery_msg

  PHASE_FILE="$phase_file"
  LAST_PHASE_MTIME=0
  _MONITOR_LOOP_EXIT=""
  local idle_elapsed=0

  while true; do
    sleep "$poll_interval"
    idle_elapsed=$(( idle_elapsed + poll_interval ))

    # --- Session health check ---
    if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
      current_phase=$(read_phase)
      case "$current_phase" in
        PHASE:done|PHASE:failed)
          # Expected terminal phases — fall through to phase dispatch below
          ;;
        *)
          log "WARNING: tmux session died unexpectedly (phase: ${current_phase:-none})"
          notify "session crashed (phase: ${current_phase:-none}), attempting recovery"

          # Attempt crash recovery: restart session with recovery context
          crash_diff=$(git -C "${WORKTREE}" diff "origin/${PRIMARY_BRANCH}..HEAD" --stat 2>/dev/null | head -20 || echo "(no diff)")
          recovery_msg="## Session Recovery

Your Claude Code session for issue #${ISSUE} was interrupted unexpectedly.
The git worktree at ${WORKTREE} is intact — your changes survived.

Last known phase: ${current_phase:-unknown}

Work so far:
${crash_diff}

Run: git log --oneline -5 && git status
Then resume from the last phase following the original phase protocol.
Phase file: ${PHASE_FILE}"

          if tmux new-session -d -s "${SESSION_NAME}" -c "${WORKTREE}" \
            "claude --dangerously-skip-permissions" 2>/dev/null; then
            inject_into_session "$recovery_msg"
            log "recovery session started"
            idle_elapsed=0
          else
            log "ERROR: could not restart session after crash"
            notify "session crashed and could not recover — needs human attention"
            _MONITOR_LOOP_EXIT="crash_recovery_failed"
            break
          fi
          continue
          ;;
      esac
    fi

    # --- Check phase file for changes ---
    phase_mtime=$(stat -c %Y "$phase_file" 2>/dev/null || echo 0)
    current_phase=$(read_phase)

    if [ -z "$current_phase" ] || [ "$phase_mtime" -le "$LAST_PHASE_MTIME" ]; then
      # No phase change — check idle timeout
      if [ "$idle_elapsed" -ge "$idle_timeout" ]; then
        log "TIMEOUT: no phase update for ${idle_timeout}s — killing session"
        kill_tmux_session
        _MONITOR_LOOP_EXIT="idle_timeout"
        break
      fi
      continue
    fi

    # Phase changed — update tracking state and dispatch to callback
    LAST_PHASE_MTIME="$phase_mtime"
    idle_elapsed=0
    log "phase: ${current_phase}"
    status "${current_phase}"

    if [ -n "$callback_fn" ]; then
      if ! "$callback_fn" "$current_phase"; then
        _MONITOR_LOOP_EXIT="callback_break"
        break
      fi
    fi
  done
}
