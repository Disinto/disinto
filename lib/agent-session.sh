#!/usr/bin/env bash
# agent-session.sh — Shared tmux + Claude interactive session helpers
#
# Source this into agent orchestrator scripts for reusable session management.
#
# Functions:
#   agent_wait_for_claude_ready SESSION_NAME [TIMEOUT_SECS]
#   agent_inject_into_session   SESSION_NAME TEXT
#   agent_kill_session          SESSION_NAME
#   monitor_phase_loop          PHASE_FILE IDLE_TIMEOUT_SECS CALLBACK_FN [SESSION_NAME]
#   session_lock_acquire        [TIMEOUT_SECS]
#   session_lock_release

# --- Cooperative session lock (fd-based) ---
# File descriptor for the session lock. Set by create_agent_session().
# Callers can release/re-acquire via session_lock_release/session_lock_acquire
# to allow other Claude sessions during idle phases (awaiting_review/awaiting_ci).
SESSION_LOCK_FD=""

# Release the session lock without closing the file descriptor.
# The fd stays open so it can be re-acquired later.
session_lock_release() {
  if [ -n "${SESSION_LOCK_FD:-}" ]; then
    flock -u "$SESSION_LOCK_FD"
  fi
}

# Re-acquire the session lock. Blocks until available or timeout.
# Opens the lock fd if not already open (for use by external callers).
# Args: [timeout_secs] (default 300)
# Returns 0 on success, 1 on timeout/error.
# shellcheck disable=SC2120  # timeout arg is used by external callers
session_lock_acquire() {
  local timeout="${1:-300}"
  if [ -z "${SESSION_LOCK_FD:-}" ]; then
    local lock_dir="${HOME}/.claude"
    mkdir -p "$lock_dir"
    exec {SESSION_LOCK_FD}>>"${lock_dir}/session.lock"
  fi
  flock -w "$timeout" "$SESSION_LOCK_FD"
}

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
  # Re-acquire session lock before injecting — Claude will resume working
  # shellcheck disable=SC2119  # using default timeout
  session_lock_acquire || true
  agent_wait_for_claude_ready "$session" 120 || true
  # Clear idle marker — new work incoming
  rm -f "/tmp/claude-idle-${session}.ts"
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
# Installs a Stop hook for idle detection (see monitor_phase_loop).
# Installs a PreToolUse hook to guard destructive Bash operations.
# Optionally installs a PostToolUse hook for phase file write detection.
# Optionally installs a StopFailure hook for immediate phase file update on API error.
# Args: session workdir [phase_file]
# Returns 0 if session is ready, 1 otherwise.
create_agent_session() {
  local session="$1"
  local workdir="${2:-.}"
  local phase_file="${3:-}"

  # Prepare settings directory for hooks
  mkdir -p "${workdir}/.claude"
  local settings="${workdir}/.claude/settings.json"

  # Install Stop hook for idle detection: when Claude finishes a response,
  # the hook writes a timestamp to a marker file. monitor_phase_loop checks
  # this marker instead of fragile tmux pane scraping.
  local idle_marker="/tmp/claude-idle-${session}.ts"
  local hook_script="${FACTORY_ROOT}/lib/hooks/on-idle-stop.sh"
  if [ -x "$hook_script" ]; then
    local hook_cmd="${hook_script} ${idle_marker}"
    # When a phase file is available, pass it and the session name so the
    # hook can nudge Claude if it returns to the prompt without signalling.
    if [ -n "$phase_file" ]; then
      hook_cmd="${hook_script} ${idle_marker} ${phase_file} ${session}"
    fi
    if [ -f "$settings" ]; then
      # Append our Stop hook to existing project settings
      jq --arg cmd "$hook_cmd" '
        if (.hooks.Stop // [] | any(.[]; .hooks[]?.command == $cmd))
        then .
        else .hooks.Stop = (.hooks.Stop // []) + [{
          matcher: "",
          hooks: [{type: "command", command: $cmd}]
        }]
        end
      ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
    else
      jq -n --arg cmd "$hook_cmd" '{
        hooks: {
          Stop: [{
            matcher: "",
            hooks: [{type: "command", command: $cmd}]
          }]
        }
      }' > "$settings"
    fi
  fi

  # Install PostToolUse hook for phase file write detection: when Claude
  # writes to the phase file via Bash or Write, the hook writes a marker
  # so monitor_phase_loop can react immediately instead of waiting for
  # the next mtime-based poll cycle.
  if [ -n "$phase_file" ]; then
    local phase_marker="/tmp/phase-changed-${session}.marker"
    local phase_hook_script="${FACTORY_ROOT}/lib/hooks/on-phase-change.sh"
    if [ -x "$phase_hook_script" ]; then
      local phase_hook_cmd="${phase_hook_script} ${phase_file} ${phase_marker}"
      if [ -f "$settings" ]; then
        jq --arg cmd "$phase_hook_cmd" '
          if (.hooks.PostToolUse // [] | any(.[]; .hooks[]?.command == $cmd))
          then .
          else .hooks.PostToolUse = (.hooks.PostToolUse // []) + [{
            matcher: "Bash|Write",
            hooks: [{type: "command", command: $cmd}]
          }]
          end
        ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
      else
        jq -n --arg cmd "$phase_hook_cmd" '{
          hooks: {
            PostToolUse: [{
              matcher: "Bash|Write",
              hooks: [{type: "command", command: $cmd}]
            }]
          }
        }' > "$settings"
      fi
      rm -f "$phase_marker"
    fi
  fi

  # Install StopFailure hook for immediate phase file update on API error:
  # when Claude hits a rate limit, server error, billing error, or auth failure,
  # the hook writes PHASE:failed to the phase file and touches the phase-changed
  # marker so monitor_phase_loop picks it up within one poll cycle instead of
  # waiting for idle timeout (up to 2 hours).
  if [ -n "$phase_file" ]; then
    local stop_failure_hook_script="${FACTORY_ROOT}/lib/hooks/on-stop-failure.sh"
    if [ -x "$stop_failure_hook_script" ]; then
      # phase_marker is defined in the PostToolUse block above; redeclare so
      # this block is self-contained if that block is ever removed.
      local sf_phase_marker="/tmp/phase-changed-${session}.marker"
      local stop_failure_hook_cmd="${stop_failure_hook_script} ${phase_file} ${sf_phase_marker}"
      if [ -f "$settings" ]; then
        jq --arg cmd "$stop_failure_hook_cmd" '
          if (.hooks.StopFailure // [] | any(.[]; .hooks[]?.command == $cmd))
          then .
          else .hooks.StopFailure = (.hooks.StopFailure // []) + [{
            matcher: "rate_limit|server_error|authentication_failed|billing_error",
            hooks: [{type: "command", command: $cmd}]
          }]
          end
        ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
      else
        jq -n --arg cmd "$stop_failure_hook_cmd" '{
          hooks: {
            StopFailure: [{
              matcher: "rate_limit|server_error|authentication_failed|billing_error",
              hooks: [{type: "command", command: $cmd}]
            }]
          }
        }' > "$settings"
      fi
    fi
  fi

  # Install PreToolUse hook for destructive operation guard: blocks force push
  # to primary branch, rm -rf outside worktree, direct API merge calls, and
  # checkout/switch to primary branch.  Claude sees the denial reason on exit 2
  # and can self-correct.
  local guard_hook_script="${FACTORY_ROOT}/lib/hooks/on-pretooluse-guard.sh"
  if [ -x "$guard_hook_script" ]; then
    local abs_workdir
    abs_workdir=$(cd "$workdir" 2>/dev/null && pwd) || abs_workdir="$workdir"
    local guard_hook_cmd="${guard_hook_script} ${PRIMARY_BRANCH:-main} ${abs_workdir} ${session}"
    if [ -f "$settings" ]; then
      jq --arg cmd "$guard_hook_cmd" '
        if (.hooks.PreToolUse // [] | any(.[]; .hooks[]?.command == $cmd))
        then .
        else .hooks.PreToolUse = (.hooks.PreToolUse // []) + [{
          matcher: "Bash",
          hooks: [{type: "command", command: $cmd}]
        }]
        end
      ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
    else
      jq -n --arg cmd "$guard_hook_cmd" '{
        hooks: {
          PreToolUse: [{
            matcher: "Bash",
            hooks: [{type: "command", command: $cmd}]
          }]
        }
      }' > "$settings"
    fi
  fi

  # Install SessionEnd hook for guaranteed cleanup: when the Claude session
  # exits (clean or crash), write a termination marker so monitor_phase_loop
  # detects the exit faster than tmux has-session polling alone.
  local exit_marker="/tmp/claude-exited-${session}.ts"
  local session_end_hook_script="${FACTORY_ROOT}/lib/hooks/on-session-end.sh"
  if [ -x "$session_end_hook_script" ]; then
    local session_end_hook_cmd="${session_end_hook_script} ${exit_marker}"
    if [ -f "$settings" ]; then
      jq --arg cmd "$session_end_hook_cmd" '
        if (.hooks.SessionEnd // [] | any(.[]; .hooks[]?.command == $cmd))
        then .
        else .hooks.SessionEnd = (.hooks.SessionEnd // []) + [{
          matcher: "",
          hooks: [{type: "command", command: $cmd}]
        }]
        end
      ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
    else
      jq -n --arg cmd "$session_end_hook_cmd" '{
        hooks: {
          SessionEnd: [{
            matcher: "",
            hooks: [{type: "command", command: $cmd}]
          }]
        }
      }' > "$settings"
    fi
  fi
  rm -f "$exit_marker"

  # Install SessionStart hook for context re-injection after compaction:
  # when Claude Code compacts context during long sessions, the phase protocol
  # instructions are lost. This hook fires after each compaction and outputs
  # the content of a context file so Claude retains critical instructions.
  # The context file is written by callers via write_compact_context().
  if [ -n "$phase_file" ]; then
    local compact_hook_script="${FACTORY_ROOT}/lib/hooks/on-compact-reinject.sh"
    if [ -x "$compact_hook_script" ]; then
      local context_file="${phase_file%.phase}.context"
      local compact_hook_cmd="${compact_hook_script} ${context_file}"
      if [ -f "$settings" ]; then
        jq --arg cmd "$compact_hook_cmd" '
          if (.hooks.SessionStart // [] | any(.[]; .hooks[]?.command == $cmd))
          then .
          else .hooks.SessionStart = (.hooks.SessionStart // []) + [{
            matcher: "compact",
            hooks: [{type: "command", command: $cmd}]
          }]
          end
        ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
      else
        jq -n --arg cmd "$compact_hook_cmd" '{
          hooks: {
            SessionStart: [{
              matcher: "compact",
              hooks: [{type: "command", command: $cmd}]
            }]
          }
        }' > "$settings"
      fi
    fi
  fi

  # Install Stop hook for Matrix streaming: when MATRIX_THREAD_ID is set,
  # each Claude response is posted to the Matrix thread so humans can follow.
  local matrix_hook_script="${FACTORY_ROOT}/lib/hooks/on-stop-matrix.sh"
  if [ -n "${MATRIX_THREAD_ID:-}" ] && [ -x "$matrix_hook_script" ]; then
    if [ -f "$settings" ]; then
      jq --arg cmd "$matrix_hook_script" '
        if (.hooks.Stop // [] | any(.[]; .hooks[]?.command == $cmd))
        then .
        else .hooks.Stop = (.hooks.Stop // []) + [{
          matcher: "",
          hooks: [{type: "command", command: $cmd}]
        }]
        end
      ' "$settings" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
    else
      jq -n --arg cmd "$matrix_hook_script" '{
        hooks: {
          Stop: [{
            matcher: "",
            hooks: [{type: "command", command: $cmd}]
          }]
        }
      }' > "$settings"
    fi
  fi

  rm -f "$idle_marker"
  local model_flag=""
  if [ -n "${CLAUDE_MODEL:-}" ]; then
    model_flag="--model ${CLAUDE_MODEL}"
  fi

  # Acquire a session-level mutex via fd-based flock to prevent concurrent
  # Claude sessions from racing on OAuth token refresh.  Unlike the previous
  # command-wrapper flock, the fd approach allows callers to release the lock
  # during idle phases (awaiting_review/awaiting_ci) and re-acquire before
  # injecting the next prompt.  See #724.
  # Use ~/.claude/session.lock so the lock is shared across containers when
  # the host ~/.claude directory is bind-mounted.
  local lock_dir="${HOME}/.claude"
  mkdir -p "$lock_dir"
  local claude_lock="${lock_dir}/session.lock"
  if [ -z "${SESSION_LOCK_FD:-}" ]; then
    exec {SESSION_LOCK_FD}>>"${claude_lock}"
  fi
  if ! flock -w 300 "$SESSION_LOCK_FD"; then
    return 1
  fi
  local claude_cmd="claude --dangerously-skip-permissions ${model_flag}"

  tmux new-session -d -s "$session" -c "$workdir" \
    "$claude_cmd" 2>/dev/null
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
# Sets _MONITOR_LOOP_EXIT to the exit reason (idle_timeout, idle_prompt, done, crashed, PHASE:failed, PHASE:escalate).
# Sets _MONITOR_SESSION to the resolved session name (arg 4 or $SESSION_NAME).
#   Callbacks should reference _MONITOR_SESSION instead of $SESSION_NAME directly.
# Args: phase_file idle_timeout_secs callback_fn [session_name]
#   session_name — tmux session to health-check; falls back to $SESSION_NAME global
#
# Idle detection: uses a Stop hook marker file (written by lib/hooks/on-idle-stop.sh)
# to detect when Claude finishes responding without writing a phase signal.
# If the marker exists for 3 consecutive polls with no phase written, the session
# is killed and the callback invoked with "PHASE:failed".
monitor_phase_loop() {
  local phase_file="$1"
  local idle_timeout="$2"
  local callback="$3"
  local _session="${4:-${SESSION_NAME:-}}"
  # Export resolved session name so callbacks can reference it regardless of
  # which session was passed to monitor_phase_loop (analogous to _MONITOR_LOOP_EXIT).
  export _MONITOR_SESSION="$_session"
  local poll_interval="${PHASE_POLL_INTERVAL:-10}"
  local last_mtime=0
  local idle_elapsed=0
  local idle_pane_count=0

  while true; do
    sleep "$poll_interval"
    idle_elapsed=$(( idle_elapsed + poll_interval ))

    # Session health check: SessionEnd hook marker provides fast detection,
    # tmux has-session is the fallback for unclean exits (e.g. tmux crash).
    local exit_marker="/tmp/claude-exited-${_session}.ts"
    if [ -f "$exit_marker" ] || ! tmux has-session -t "${_session}" 2>/dev/null; then
      local current_phase
      current_phase=$(head -1 "$phase_file" 2>/dev/null | tr -d '[:space:]' || true)
      case "$current_phase" in
        PHASE:done|PHASE:failed|PHASE:merged|PHASE:escalate)
          ;; # terminal — fall through to phase handler
        *)
          # Call callback with "crashed" — let agent-specific code handle recovery
          if type "${callback}" &>/dev/null; then
            "$callback" "PHASE:crashed"
          fi
          # If callback didn't restart session, break
          if ! tmux has-session -t "${_session}" 2>/dev/null; then
            _MONITOR_LOOP_EXIT="crashed"
            return 1
          fi
          idle_elapsed=0
          idle_pane_count=0
          continue
          ;;
      esac
    fi

    # Check phase-changed marker from PostToolUse hook — if present, the hook
    # detected a phase file write so we reset last_mtime to force processing
    # this cycle instead of waiting for the next mtime change.
    local phase_marker="/tmp/phase-changed-${_session}.marker"
    if [ -f "$phase_marker" ]; then
      rm -f "$phase_marker"
      last_mtime=0
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
        agent_kill_session "${_session}"
        return 0
      fi
      # Idle detection via Stop hook: the on-idle-stop.sh hook writes a marker
      # file when Claude finishes a response. If the marker exists and no phase
      # has been written, Claude returned to the prompt without following the
      # phase protocol. 3 consecutive polls = confirmed idle (not mid-turn).
      local idle_marker="/tmp/claude-idle-${_session}.ts"
      if [ -z "$current_phase" ] && [ -f "$idle_marker" ]; then
        idle_pane_count=$(( idle_pane_count + 1 ))
        if [ "$idle_pane_count" -ge 3 ]; then
          _MONITOR_LOOP_EXIT="idle_prompt"
          # Session is killed before the callback is invoked.
          # Callbacks that handle PHASE:failed must not assume the session is alive.
          agent_kill_session "${_session}"
          if type "${callback}" &>/dev/null; then
            "$callback" "PHASE:failed"
          fi
          return 0
        fi
      else
        idle_pane_count=0
      fi
      continue
    fi

    # Phase changed
    last_mtime="$phase_mtime"
    # shellcheck disable=SC2034  # read by phase-handler.sh callback
    LAST_PHASE_MTIME="$phase_mtime"
    idle_elapsed=0
    idle_pane_count=0

    # Terminal phases
    case "$current_phase" in
      PHASE:done|PHASE:merged)
        _MONITOR_LOOP_EXIT="done"
        if type "${callback}" &>/dev/null; then
          "$callback" "$current_phase"
        fi
        return 0
        ;;
      PHASE:failed|PHASE:escalate)
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

# Write context to a file for re-injection after context compaction.
# The SessionStart compact hook reads this file and outputs it to stdout.
# Args: phase_file content
write_compact_context() {
  local phase_file="$1"
  local content="$2"
  local context_file="${phase_file%.phase}.context"
  printf '%s\n' "$content" > "$context_file"
}

# Kill a tmux session gracefully (no-op if not found).
agent_kill_session() {
  local session="${1:-}"
  [ -n "$session" ] && tmux kill-session -t "$session" 2>/dev/null || true
  rm -f "/tmp/claude-idle-${session}.ts"
  rm -f "/tmp/phase-changed-${session}.marker"
  rm -f "/tmp/claude-exited-${session}.ts"
  rm -f "/tmp/claude-nudge-${session}.count"
}

# Read the current phase from a phase file, stripped of whitespace.
# Usage: read_phase [file]  — defaults to $PHASE_FILE
read_phase() {
  local file="${1:-${PHASE_FILE:-}}"
  { cat "$file" 2>/dev/null || true; } | head -1 | tr -d '[:space:]'
}
