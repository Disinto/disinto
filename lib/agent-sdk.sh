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

# claude_run_with_watchdog — run claude with idle-after-final-message watchdog
#
# Mitigates upstream Claude Code hang (#591) by detecting when the final
# assistant message has been written and terminating the process after a
# short grace period instead of waiting for CLAUDE_TIMEOUT.
#
# The watchdog:
#   1. Streams claude stdout to a temp file
#   2. Polls for the final result marker ("type":"result" for stream-json
#      or closing } for regular json output)
#   3. After detecting the final marker, starts a CLAUDE_IDLE_GRACE countdown
#   4. SIGTERM claude if it hasn't exited cleanly within the grace period
#   5. Falls back to CLAUDE_TIMEOUT as the absolute hard ceiling
#
# Usage: claude_run_with_watchdog claude [args...]
# Expects: LOGFILE, CLAUDE_TIMEOUT, CLAUDE_IDLE_GRACE (default 30)
# Returns: exit code from claude or timeout
claude_run_with_watchdog() {
  local -a cmd=("$@")
  local out_file pid grace_pid rc

  # Create temp file for stdout capture
  out_file=$(mktemp) || return 1
  trap 'rm -f "$out_file"' RETURN

  # Start claude in background, capturing stdout to temp file
  "${cmd[@]}" > "$out_file" 2>>"$LOGFILE" &
  pid=$!

  # Background watchdog: poll for final result marker
  (
    local grace="${CLAUDE_IDLE_GRACE:-30}"
    local detected=0

    while kill -0 "$pid" 2>/dev/null; do
      # Check for stream-json result marker first (more reliable)
      if grep -q '"type":"result"' "$out_file" 2>/dev/null; then
        detected=1
        break
      fi
      # Fallback: check for closing brace of top-level result object
      if tail -c 100 "$out_file" 2>/dev/null | grep -q '}[[:space:]]*$'; then
        # Verify it looks like a JSON result (has session_id or result key)
        if grep -qE '"(session_id|result)":' "$out_file" 2>/dev/null; then
          detected=1
          break
        fi
      fi
      sleep 2
    done

    # If we detected a final message, wait grace period then kill if still running
    if [ "$detected" -eq 1 ] && kill -0 "$pid" 2>/dev/null; then
      log "watchdog: final result detected, ${grace}s grace period before SIGTERM"
      sleep "$grace"
      if kill -0 "$pid" 2>/dev/null; then
        log "watchdog: claude -p idle for ${grace}s after final result; SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        # Give it a moment to clean up
        sleep 5
        if kill -0 "$pid" 2>/dev/null; then
          log "watchdog: force kill after SIGTERM timeout"
          kill -KILL "$pid" 2>/dev/null || true
        fi
      fi
    fi
  ) &
  grace_pid=$!

  # Hard ceiling timeout (existing behavior) — use tail --pid to wait for process
  timeout --foreground "${CLAUDE_TIMEOUT:-7200}" tail --pid="$pid" -f /dev/null 2>/dev/null
  rc=$?

  # Clean up the watchdog
  kill "$grace_pid" 2>/dev/null || true
  wait "$grace_pid" 2>/dev/null || true

  # When timeout fires (rc=124), explicitly kill the orphaned claude process
  # tail --pid is a passive waiter, not a supervisor
  if [ "$rc" -eq 124 ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
  fi

  # Output the captured stdout
  cat "$out_file"
  return "$rc"
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

  _AGENT_LAST_OUTPUT=""

  local -a args=(-p "$prompt" --output-format json --dangerously-skip-permissions --max-turns 200)
  [ -n "$resume_id" ] && args+=(--resume "$resume_id")
  [ -n "${CLAUDE_MODEL:-}" ] && args+=(--model "$CLAUDE_MODEL")

  local run_dir="${worktree_dir:-$(pwd)}"
  local lock_file="${HOME}/.claude/session.lock"
  local output rc
  log "agent_run: starting (resume=${resume_id:-(new)}, dir=${run_dir})"
  # External flock is redundant once CLAUDE_CONFIG_DIR rollout is verified (#647).
  # Gate behind CLAUDE_EXTERNAL_LOCK for rollback safety; default off.
  if [ -n "${CLAUDE_EXTERNAL_LOCK:-}" ]; then
    mkdir -p "$(dirname "$lock_file")"
    output=$(cd "$run_dir" && ( flock -w 600 9 || exit 1; claude_run_with_watchdog claude "${args[@]}" ) 9>"$lock_file" 2>>"$LOGFILE") && rc=0 || rc=$?
  else
    output=$(cd "$run_dir" && claude_run_with_watchdog claude "${args[@]}" 2>>"$LOGFILE") && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    log "agent_run: timeout after ${CLAUDE_TIMEOUT:-7200}s (exit code $rc)"
  elif [ "$rc" -ne 0 ]; then
    log "agent_run: claude exited with code $rc"
    # Log last 3 lines of output for diagnostics
    if [ -n "$output" ]; then
      log "agent_run: last output lines: $(echo "$output" | tail -3)"
    fi
  fi
  if [ -z "$output" ]; then
    log "agent_run: empty output (claude may have crashed or failed, exit code: $rc)"
  fi

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
  local diag_dir="${DISINTO_LOG_DIR:-/tmp}/${LOG_AGENT:-dev}"
  mkdir -p "$diag_dir" 2>/dev/null || true
  local diag_file="${diag_dir}/agent-run-last.json"
  printf '%s' "$output" > "$diag_file" 2>/dev/null || true

  # Nudge: if the model stopped without pushing, resume with encouragement.
  # Some models emit end_turn prematurely when confused. A nudge often unsticks them.
  if [ -n "$_AGENT_SESSION_ID" ] && [ -n "$output" ]; then
    local has_changes
    has_changes=$(cd "$run_dir" && git status --porcelain 2>/dev/null | head -1) || true
    local has_pushed
    has_pushed=$(cd "$run_dir" && git log --oneline "${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH:-main}..HEAD" 2>/dev/null | head -1) || true
    if [ -z "$has_pushed" ]; then
      if [ -n "$has_changes" ]; then
        # Nudge: there are uncommitted changes
        local nudge="You stopped but did not push any code. You have uncommitted changes. Commit them and push."
        log "agent_run: nudging (uncommitted changes)"
        local nudge_rc
        if [ -n "${CLAUDE_EXTERNAL_LOCK:-}" ]; then
          output=$(cd "$run_dir" && ( flock -w 600 9 || exit 1; claude_run_with_watchdog claude -p "$nudge" --resume "$_AGENT_SESSION_ID" --output-format json --dangerously-skip-permissions --max-turns 50 ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} ) 9>"$lock_file" 2>>"$LOGFILE") && nudge_rc=0 || nudge_rc=$?
        else
          output=$(cd "$run_dir" && claude_run_with_watchdog claude -p "$nudge" --resume "$_AGENT_SESSION_ID" --output-format json --dangerously-skip-permissions --max-turns 50 ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} 2>>"$LOGFILE") && nudge_rc=0 || nudge_rc=$?
        fi
        if [ "$nudge_rc" -eq 124 ]; then
          log "agent_run: nudge timeout after ${CLAUDE_TIMEOUT:-7200}s (exit code $nudge_rc)"
        elif [ "$nudge_rc" -ne 0 ]; then
          log "agent_run: nudge claude exited with code $nudge_rc"
          # Log last 3 lines of output for diagnostics
          if [ -n "$output" ]; then
            log "agent_run: nudge last output lines: $(echo "$output" | tail -3)"
          fi
        fi
        new_sid=$(printf '%s' "$output" | jq -r '.session_id // empty' 2>/dev/null) || true
        if [ -n "$new_sid" ]; then
          _AGENT_SESSION_ID="$new_sid"
          printf '%s' "$new_sid" > "$SID_FILE"
        fi
        printf '%s' "$output" > "$diag_file" 2>/dev/null || true
        _AGENT_LAST_OUTPUT="$output"
      else
        log "agent_run: no push and no changes — skipping nudge"
      fi
    fi
  fi
}
