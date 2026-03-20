#!/usr/bin/env bash
# formula-session.sh — Shared helpers for formula-driven cron agents
#
# Provides reusable functions for the common cron-wrapper + tmux-session
# pattern used by planner-run.sh and gardener-agent.sh.
#
# Functions:
#   acquire_cron_lock   LOCK_FILE          — PID lock with stale cleanup
#   check_memory        [MIN_MB]           — skip if available RAM too low
#   load_formula        FORMULA_FILE       — sets FORMULA_CONTENT
#   build_context_block FILE [FILE ...]    — sets CONTEXT_BLOCK
#   start_formula_session SESSION WORKDIR PHASE_FILE — create tmux + claude
#   formula_phase_callback PHASE           — standard crash-recovery callback
#
# Requires: lib/agent-session.sh sourced first (for create_agent_session,
# agent_kill_session, agent_inject_into_session).
# Globals used by formula_phase_callback: SESSION_NAME, PHASE_FILE,
# PROJECT_REPO_ROOT, PROMPT (set by the calling script).

# ── Cron guards ──────────────────────────────────────────────────────────

# acquire_cron_lock LOCK_FILE
# Acquires a PID lock. Exits 0 if another instance is running.
# Sets an EXIT trap to clean up the lock file.
acquire_cron_lock() {
  _CRON_LOCK_FILE="$1"
  if [ -f "$_CRON_LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$_CRON_LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "run: already running (PID $lock_pid)"
      exit 0
    fi
    rm -f "$_CRON_LOCK_FILE"
  fi
  echo $$ > "$_CRON_LOCK_FILE"
  trap 'rm -f "$_CRON_LOCK_FILE"' EXIT
}

# check_memory [MIN_MB]
# Exits 0 (skip) if available memory is below MIN_MB (default 2000).
check_memory() {
  local min_mb="${1:-2000}"
  local avail_mb
  avail_mb=$(free -m | awk '/Mem:/{print $7}')
  if [ "${avail_mb:-0}" -lt "$min_mb" ]; then
    log "run: skipping — only ${avail_mb}MB available (need ${min_mb})"
    exit 0
  fi
}

# ── Formula loading ──────────────────────────────────────────────────────

# load_formula FORMULA_FILE
# Reads formula TOML into FORMULA_CONTENT. Exits 1 if missing.
load_formula() {
  local formula_file="$1"
  if [ ! -f "$formula_file" ]; then
    log "ERROR: formula not found: $formula_file"
    exit 1
  fi
  # shellcheck disable=SC2034  # consumed by the calling script
  FORMULA_CONTENT=$(cat "$formula_file")
}

# build_context_block FILE [FILE ...]
# Reads each file from $PROJECT_REPO_ROOT and builds CONTEXT_BLOCK.
build_context_block() {
  CONTEXT_BLOCK=""
  local ctx ctx_path
  for ctx in "$@"; do
    ctx_path="${PROJECT_REPO_ROOT}/${ctx}"
    if [ -f "$ctx_path" ]; then
      CONTEXT_BLOCK="${CONTEXT_BLOCK}
### ${ctx}
$(cat "$ctx_path")
"
    fi
  done
}

# ── Session management ───────────────────────────────────────────────────

# start_formula_session SESSION WORKDIR PHASE_FILE
# Kills stale session, resets phase file, creates new tmux + claude session.
# Returns 0 on success, 1 on failure.
start_formula_session() {
  local session="$1" workdir="$2" phase_file="$3"
  agent_kill_session "$session"
  rm -f "$phase_file"
  log "Creating tmux session: ${session}"
  if ! create_agent_session "$session" "$workdir" "$phase_file"; then
    log "ERROR: failed to create tmux session ${session}"
    return 1
  fi
}

# formula_phase_callback PHASE
# Standard crash-recovery phase callback for formula sessions.
# Requires globals: SESSION_NAME, PHASE_FILE, PROJECT_REPO_ROOT, PROMPT.
# Uses _FORMULA_CRASH_COUNT (auto-initialized) for single-retry limit.
# shellcheck disable=SC2154  # SESSION_NAME, PHASE_FILE, PROJECT_REPO_ROOT, PROMPT set by caller
formula_phase_callback() {
  local phase="$1"
  log "phase: ${phase}"
  case "$phase" in
    PHASE:crashed)
      if [ "${_FORMULA_CRASH_COUNT:-0}" -gt 0 ]; then
        log "ERROR: session crashed again after recovery — giving up"
        return 0
      fi
      _FORMULA_CRASH_COUNT=$(( ${_FORMULA_CRASH_COUNT:-0} + 1 ))
      log "WARNING: tmux session died unexpectedly — attempting recovery"
      if create_agent_session "${_MONITOR_SESSION:-$SESSION_NAME}" "$PROJECT_REPO_ROOT" "$PHASE_FILE" 2>/dev/null; then
        agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" "$PROMPT"
        log "Recovery session started"
      else
        log "ERROR: could not restart session after crash"
      fi
      ;;
    PHASE:done|PHASE:failed|PHASE:needs_human|PHASE:merged)
      agent_kill_session "${_MONITOR_SESSION:-$SESSION_NAME}"
      ;;
  esac
}
