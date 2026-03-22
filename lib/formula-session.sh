#!/usr/bin/env bash
# formula-session.sh — Shared helpers for formula-driven cron agents
#
# Provides reusable functions for the common cron-wrapper + tmux-session
# pattern used by planner-run.sh, predictor-run.sh, gardener-run.sh, and supervisor-run.sh.
#
# Functions:
#   acquire_cron_lock   LOCK_FILE          — PID lock with stale cleanup
#   check_memory        [MIN_MB]           — skip if available RAM too low
#   load_formula        FORMULA_FILE       — sets FORMULA_CONTENT
#   build_context_block FILE [FILE ...]    — sets CONTEXT_BLOCK
#   start_formula_session SESSION WORKDIR PHASE_FILE — create tmux + claude
#   build_prompt_footer    [EXTRA_API]      — sets PROMPT_FOOTER (API ref + env + phase)
#   run_formula_and_monitor AGENT [TIMEOUT] [CALLBACK] — session start, inject, monitor, log
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

# ── Escalation reply consumption ─────────────────────────────────────────

# consume_escalation_reply AGENT_NAME
# Atomically consumes /tmp/{agent}-escalation-reply if it exists.
# Sets ESCALATION_REPLY to the file contents (empty string if no reply).
consume_escalation_reply() {
  local agent="$1"
  local reply_file="/tmp/${agent}-escalation-reply"
  ESCALATION_REPLY=""
  if [ -s "$reply_file" ]; then
    local tmp_file="${reply_file}.consumed.$$"
    if mv "$reply_file" "$tmp_file" 2>/dev/null; then
      ESCALATION_REPLY=$(cat "$tmp_file")
      rm -f "$tmp_file"
      log "Consumed escalation reply: $(echo "$ESCALATION_REPLY" | head -1)"
    fi
  fi
}

# ── Session management ───────────────────────────────────────────────────

# start_formula_session SESSION WORKDIR PHASE_FILE
# Kills stale session, resets phase file, creates a per-agent git worktree
# for session isolation, and creates a new tmux + claude session in it.
# Sets _FORMULA_SESSION_WORKDIR to the worktree path (or original workdir
# on fallback). Callers must clean up via remove_formula_worktree after
# the session ends.
# Returns 0 on success, 1 on failure.
start_formula_session() {
  local session="$1" workdir="$2" phase_file="$3"
  agent_kill_session "$session"
  rm -f "$phase_file"

  # Create per-agent git worktree for session isolation.
  # Each agent gets its own CWD so Claude Code treats them as separate
  # projects — no resume collisions between sequential formula runs.
  _FORMULA_SESSION_WORKDIR="/tmp/disinto-${session}"
  # Clean up any stale worktree from a previous run
  git -C "$workdir" worktree remove "$_FORMULA_SESSION_WORKDIR" --force 2>/dev/null || true
  if git -C "$workdir" worktree add "$_FORMULA_SESSION_WORKDIR" HEAD --detach 2>/dev/null; then
    log "Created worktree: ${_FORMULA_SESSION_WORKDIR}"
  else
    log "WARNING: worktree creation failed — falling back to ${workdir}"
    _FORMULA_SESSION_WORKDIR="$workdir"
  fi

  log "Creating tmux session: ${session}"
  if ! create_agent_session "$session" "$_FORMULA_SESSION_WORKDIR" "$phase_file"; then
    log "ERROR: failed to create tmux session ${session}"
    return 1
  fi
}

# remove_formula_worktree
# Removes the worktree created by start_formula_session if it differs from
# PROJECT_REPO_ROOT. Safe to call multiple times. No-op if no worktree was created.
remove_formula_worktree() {
  if [ -n "${_FORMULA_SESSION_WORKDIR:-}" ] \
     && [ "$_FORMULA_SESSION_WORKDIR" != "${PROJECT_REPO_ROOT:-}" ]; then
    git -C "$PROJECT_REPO_ROOT" worktree remove "$_FORMULA_SESSION_WORKDIR" --force 2>/dev/null || true
    log "Removed worktree: ${_FORMULA_SESSION_WORKDIR}"
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
      if create_agent_session "${_MONITOR_SESSION:-$SESSION_NAME}" "${_FORMULA_SESSION_WORKDIR:-$PROJECT_REPO_ROOT}" "$PHASE_FILE" 2>/dev/null; then
        agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" "$PROMPT"
        log "Recovery session started"
      else
        log "ERROR: could not restart session after crash"
      fi
      ;;
    PHASE:done|PHASE:failed|PHASE:escalate|PHASE:merged)
      agent_kill_session "${_MONITOR_SESSION:-$SESSION_NAME}"
      ;;
  esac
}

# ── Scratch file helpers (compaction survival) ────────────────────────────

# build_scratch_instruction SCRATCH_FILE
# Returns a prompt block instructing Claude to periodically flush context
# to a scratch file so understanding survives context compaction.
build_scratch_instruction() {
  local scratch_file="$1"
  cat <<_SCRATCH_EOF_
## Context scratch file (compaction survival)

Periodically (every 10-15 tool calls), write a summary of:
- What you have discovered so far
- Decisions made and why
- What remains to do
to: ${scratch_file}

If this file existed at session start, its contents have already been injected into your prompt above.
This file is ephemeral — not evidence or permanent memory, just a compaction survival mechanism.
_SCRATCH_EOF_
}

# read_scratch_context SCRATCH_FILE
# If the scratch file exists, returns a context block for prompt injection.
# Returns empty string if the file does not exist.
read_scratch_context() {
  local scratch_file="$1"
  if [ -f "$scratch_file" ]; then
    printf '## Previous context (from scratch file)\n%s\n' "$(head -c 8192 "$scratch_file")"
  fi
}

# ── Prompt + monitor helpers ──────────────────────────────────────────────

# build_prompt_footer [EXTRA_API_LINES]
# Assembles the common Codeberg API reference + environment + phase protocol
# block for formula prompts.  Sets PROMPT_FOOTER.
# Pass additional API endpoint lines (pre-formatted, newline-prefixed) via $1.
# Requires globals: CODEBERG_API, FACTORY_ROOT, PROJECT_REPO_ROOT,
#                   PRIMARY_BRANCH, PHASE_FILE.
build_prompt_footer() {
  local extra_api="${1:-}"
  # shellcheck disable=SC2034  # consumed by the calling script's PROMPT
  PROMPT_FOOTER="## Codeberg API reference
Base URL: ${CODEBERG_API}
Auth header: -H \"Authorization: token \$CODEBERG_TOKEN\"
  Read issue:  curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/issues/{number}' | jq '.body'
  Create issue: curl -sf -X POST -H \"Authorization: token \$CODEBERG_TOKEN\" -H 'Content-Type: application/json' '${CODEBERG_API}/issues' -d '{\"title\":\"...\",\"body\":\"...\",\"labels\":[LABEL_ID]}'${extra_api}
  List labels: curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/labels'
NEVER echo or include the actual token value in output — always reference \$CODEBERG_TOKEN.

## Environment
FACTORY_ROOT=${FACTORY_ROOT}
PROJECT_REPO_ROOT=${PROJECT_REPO_ROOT}
PRIMARY_BRANCH=${PRIMARY_BRANCH}
PHASE_FILE=${PHASE_FILE}

## Phase protocol (REQUIRED)
When all work is done:
  echo 'PHASE:done' > '${PHASE_FILE}'
On unrecoverable error:
  printf 'PHASE:failed\nReason: %s\n' 'describe error' > '${PHASE_FILE}'"
}

# run_formula_and_monitor AGENT_NAME [TIMEOUT]
# Starts the formula session, injects PROMPT, monitors phase, and logs result.
# Requires globals: SESSION_NAME, PHASE_FILE, PROJECT_REPO_ROOT, PROMPT,
#                   CODEBERG_REPO, CLAUDE_MODEL (exported).
# shellcheck disable=SC2154  # SESSION_NAME, PHASE_FILE, PROJECT_REPO_ROOT, PROMPT set by caller
run_formula_and_monitor() {
  local agent_name="$1"
  local timeout="${2:-7200}"
  local callback="${3:-formula_phase_callback}"

  if ! start_formula_session "$SESSION_NAME" "$PROJECT_REPO_ROOT" "$PHASE_FILE"; then
    exit 1
  fi

  # Write phase protocol to context file for compaction survival
  if [ -n "${PROMPT_FOOTER:-}" ]; then
    write_compact_context "$PHASE_FILE" "$PROMPT_FOOTER"
  fi

  agent_inject_into_session "$SESSION_NAME" "$PROMPT"
  log "Prompt sent to tmux session"
  matrix_send "$agent_name" "${agent_name^} session started for ${CODEBERG_REPO}" 2>/dev/null || true

  log "Monitoring phase file: ${PHASE_FILE}"
  _FORMULA_CRASH_COUNT=0

  monitor_phase_loop "$PHASE_FILE" "$timeout" "$callback"

  FINAL_PHASE=$(read_phase "$PHASE_FILE")
  log "Final phase: ${FINAL_PHASE:-none}"

  if [ "$FINAL_PHASE" != "PHASE:done" ]; then
    case "${_MONITOR_LOOP_EXIT:-}" in
      idle_prompt)
        log "${agent_name}: Claude returned to prompt without writing phase signal"
        ;;
      idle_timeout)
        log "${agent_name}: timed out with no phase signal"
        ;;
      *)
        log "${agent_name} finished without PHASE:done (phase: ${FINAL_PHASE:-none}, exit: ${_MONITOR_LOOP_EXIT:-})"
        ;;
    esac
  fi

  matrix_send "$agent_name" "${agent_name^} session finished (${FINAL_PHASE:-no phase})" 2>/dev/null || true

  # Clean up per-agent worktree — "the runtime creates and destroys"
  remove_formula_worktree

  log "--- ${agent_name^} run done ---"
}
