#!/usr/bin/env bash
# =============================================================================
# planner-run.sh — Cron wrapper: direct planner execution via Claude + formula
#
# Runs weekly (or on-demand). Guards against concurrent runs and low memory.
# Creates a tmux session with Claude (opus) reading formulas/run-planner.toml.
# No action issues — the planner is a nervous system component, not work.
#
# The planner plans for ALL projects (harb + disinto) but is itself disinto
# infrastructure — always sources projects/disinto.toml.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Source disinto project config — the planner is disinto infrastructure
export PROJECT_TOML="$FACTORY_ROOT/projects/disinto.toml"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"

LOG_FILE="$SCRIPT_DIR/planner.log"
LOCK_FILE="/tmp/planner-run.lock"
SESSION_NAME="planner-${PROJECT_NAME}"
PHASE_FILE="/tmp/planner-session-${PROJECT_NAME}.phase"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "run: planner running (PID $LOCK_PID)"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ── Memory guard ──────────────────────────────────────────────────────────
AVAIL_MB=$(free -m | awk '/Mem:/{print $7}')
if [ "${AVAIL_MB:-0}" -lt 2000 ]; then
  log "run: skipping — only ${AVAIL_MB}MB available (need 2000)"
  exit 0
fi

log "--- Planner run start ---"

# ── Load formula ─────────────────────────────────────────────────────────
FORMULA_FILE="$FACTORY_ROOT/formulas/run-planner.toml"
if [ ! -f "$FORMULA_FILE" ]; then
  log "ERROR: formula not found: $FORMULA_FILE"
  exit 1
fi
FORMULA_CONTENT=$(cat "$FORMULA_FILE")

# ── Read context files ───────────────────────────────────────────────────
CONTEXT_BLOCK=""
for ctx in VISION.md AGENTS.md RESOURCES.md; do
  ctx_path="${PROJECT_REPO_ROOT}/${ctx}"
  if [ -f "$ctx_path" ]; then
    CONTEXT_BLOCK="${CONTEXT_BLOCK}
### ${ctx}
$(cat "$ctx_path")
"
  fi
done

# ── Read planner memory ─────────────────────────────────────────────────
MEMORY_BLOCK=""
MEMORY_FILE="$FACTORY_ROOT/planner/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
  MEMORY_BLOCK="
### planner/MEMORY.md (persistent memory from prior runs)
$(cat "$MEMORY_FILE")
"
fi

# ── Build prompt ─────────────────────────────────────────────────────────
PROMPT="You are the strategic planner for ${CODEBERG_REPO}. Work through the formula below. You MUST write PHASE:done to '${PHASE_FILE}' when finished — the orchestrator will time you out if you return to the prompt without signalling.

## Project context
${CONTEXT_BLOCK}${MEMORY_BLOCK}

## Formula
${FORMULA_CONTENT}

## Codeberg API reference
Base URL: ${CODEBERG_API}
Auth header: -H \"Authorization: token \$CODEBERG_TOKEN\"
  Read issue:  curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/issues/{number}' | jq '.body'
  Create issue: curl -sf -X POST -H \"Authorization: token \$CODEBERG_TOKEN\" -H 'Content-Type: application/json' '${CODEBERG_API}/issues' -d '{\"title\":\"...\",\"body\":\"...\",\"labels\":[LABEL_ID]}'
  Relabel:     curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PUT -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/labels' -d '{\"labels\":[LABEL_ID]}'
  Comment:     curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X POST -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'
  Close:       curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"state\":\"closed\"}'
  List labels: curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/labels'
NEVER echo or include the actual token value in output — always reference \$CODEBERG_TOKEN.

## Environment
FACTORY_ROOT=${FACTORY_ROOT}
PROJECT_REPO_ROOT=${PROJECT_REPO_ROOT}
PRIMARY_BRANCH=${PRIMARY_BRANCH}

## Phase protocol (REQUIRED)
When all work is done:
  echo 'PHASE:done' > '${PHASE_FILE}'
On unrecoverable error:
  printf 'PHASE:failed\nReason: %s\n' 'describe error' > '${PHASE_FILE}'"

# ── Reset phase file + kill stale session ────────────────────────────────
agent_kill_session "$SESSION_NAME"
rm -f "$PHASE_FILE"

# ── Create tmux session ─────────────────────────────────────────────────
log "Creating tmux session: ${SESSION_NAME}"
export CLAUDE_MODEL="opus"
if ! create_agent_session "$SESSION_NAME" "$PROJECT_REPO_ROOT" "$PHASE_FILE"; then
  log "ERROR: failed to create tmux session ${SESSION_NAME}"
  exit 1
fi

agent_inject_into_session "$SESSION_NAME" "$PROMPT"
log "Prompt sent to tmux session"
matrix_send "planner" "Planner session started for ${CODEBERG_REPO}" 2>/dev/null || true

# ── Phase monitoring loop ────────────────────────────────────────────────
log "Monitoring phase file: ${PHASE_FILE}"
PLANNER_CRASH_COUNT=0

planner_phase_callback() {
  local phase="$1"
  log "phase: ${phase}"
  case "$phase" in
    PHASE:crashed)
      if [ "$PLANNER_CRASH_COUNT" -gt 0 ]; then
        log "ERROR: session crashed again after recovery — giving up"
        return 0
      fi
      PLANNER_CRASH_COUNT=$((PLANNER_CRASH_COUNT + 1))
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

monitor_phase_loop "$PHASE_FILE" 7200 "planner_phase_callback"

FINAL_PHASE=$(read_phase "$PHASE_FILE")
log "Final phase: ${FINAL_PHASE:-none}"

if [ "$FINAL_PHASE" != "PHASE:done" ]; then
  case "${_MONITOR_LOOP_EXIT:-}" in
    idle_prompt)
      log "planner: Claude returned to prompt without writing phase signal"
      ;;
    idle_timeout)
      log "planner: timed out after 2h with no phase signal"
      ;;
    *)
      log "planner finished without PHASE:done (phase: ${FINAL_PHASE:-none}, exit: ${_MONITOR_LOOP_EXIT:-})"
      ;;
  esac
fi

matrix_send "planner" "Planner session finished (${FINAL_PHASE:-no phase})" 2>/dev/null || true
log "--- Planner run done ---"
