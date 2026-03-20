#!/usr/bin/env bash
# =============================================================================
# predictor-run.sh — Cron wrapper: predictor execution via Claude + formula
#
# Runs daily (or on-demand). Guards against concurrent runs and low memory.
# Creates a tmux session with Claude (sonnet) reading formulas/run-predictor.toml.
# Files prediction/unreviewed issues for the planner to triage.
#
# Usage:
#   predictor-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Cron: 0 6 * * * cd /path/to/dark-factory && bash predictor/predictor-run.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"

LOG_FILE="$SCRIPT_DIR/predictor.log"
SESSION_NAME="predictor-${PROJECT_NAME}"
PHASE_FILE="/tmp/predictor-session-${PROJECT_NAME}.phase"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
acquire_cron_lock "/tmp/predictor-run.lock"
check_memory 2000

log "--- Predictor run start ---"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-predictor.toml"
build_context_block AGENTS.md RESOURCES.md

# ── Build prompt ─────────────────────────────────────────────────────────
PROMPT="You are the prediction agent (goblin) for ${CODEBERG_REPO}. Work through the formula below. You MUST write PHASE:done to '${PHASE_FILE}' when finished — the orchestrator will time you out if you return to the prompt without signalling.

Your role: spot patterns in infrastructure signals and file them as prediction issues.
The planner (adult) will triage every prediction before acting.
You MUST NOT emit feature work or implementation issues — only predictions
about CI health, issue staleness, agent status, and system conditions.

## Project context
${CONTEXT_BLOCK}

## Formula
${FORMULA_CONTENT}

## Codeberg API reference
Base URL: ${CODEBERG_API}
Auth header: -H \"Authorization: token \$CODEBERG_TOKEN\"
  Read issue:  curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/issues/{number}' | jq '.body'
  Create issue: curl -sf -X POST -H \"Authorization: token \$CODEBERG_TOKEN\" -H 'Content-Type: application/json' '${CODEBERG_API}/issues' -d '{\"title\":\"...\",\"body\":\"...\",\"labels\":[LABEL_ID]}'
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

# ── Create tmux session ─────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"
if ! start_formula_session "$SESSION_NAME" "$PROJECT_REPO_ROOT" "$PHASE_FILE"; then
  exit 1
fi

agent_inject_into_session "$SESSION_NAME" "$PROMPT"
log "Prompt sent to tmux session"
matrix_send "predictor" "Predictor session started for ${CODEBERG_REPO}" 2>/dev/null || true

# ── Phase monitoring loop ────────────────────────────────────────────────
log "Monitoring phase file: ${PHASE_FILE}"
_FORMULA_CRASH_COUNT=0

monitor_phase_loop "$PHASE_FILE" 7200 "formula_phase_callback"

FINAL_PHASE=$(read_phase "$PHASE_FILE")
log "Final phase: ${FINAL_PHASE:-none}"

if [ "$FINAL_PHASE" != "PHASE:done" ]; then
  case "${_MONITOR_LOOP_EXIT:-}" in
    idle_prompt)
      log "predictor: Claude returned to prompt without writing phase signal"
      ;;
    idle_timeout)
      log "predictor: timed out after 2h with no phase signal"
      ;;
    *)
      log "predictor finished without PHASE:done (phase: ${FINAL_PHASE:-none}, exit: ${_MONITOR_LOOP_EXIT:-})"
      ;;
  esac
fi

matrix_send "predictor" "Predictor session finished (${FINAL_PHASE:-no phase})" 2>/dev/null || true
log "--- Predictor run done ---"
