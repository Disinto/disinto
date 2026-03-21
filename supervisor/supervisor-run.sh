#!/usr/bin/env bash
# =============================================================================
# supervisor-run.sh — Cron wrapper: supervisor execution via Claude + formula
#
# Runs every 20 minutes (or on-demand). Guards against concurrent runs and
# low memory. Collects metrics via preflight.sh, then creates a tmux session
# with Claude (sonnet) reading formulas/run-supervisor.toml.
#
# Replaces supervisor-poll.sh (bash orchestrator + claude -p one-shot) with
# formula-driven interactive Claude session matching the planner/predictor
# pattern.
#
# Usage:
#   supervisor-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Cron: */20 * * * * cd /path/to/dark-factory && bash supervisor/supervisor-run.sh
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

LOG_FILE="$SCRIPT_DIR/supervisor.log"
# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
SESSION_NAME="supervisor-${PROJECT_NAME}"
PHASE_FILE="/tmp/supervisor-session-${PROJECT_NAME}.phase"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

SCRATCH_FILE="/tmp/supervisor-${PROJECT_NAME}-scratch.md"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
acquire_cron_lock "/tmp/supervisor-run.lock"
check_memory 2000

log "--- Supervisor run start ---"

# ── Collect pre-flight metrics ────────────────────────────────────────────
log "Running preflight.sh"
PREFLIGHT_OUTPUT=""
if PREFLIGHT_OUTPUT=$(bash "$SCRIPT_DIR/preflight.sh" "$PROJECT_TOML" 2>&1); then
  log "Preflight collected ($(echo "$PREFLIGHT_OUTPUT" | wc -l) lines)"
else
  log "WARNING: preflight.sh failed, continuing with partial data"
fi

# ── Consume escalation replies ────────────────────────────────────────────
# Move the file atomically so matrix_listener can write a new one
ESCALATION_REPLY=""
if [ -s /tmp/supervisor-escalation-reply ]; then
  _reply_tmp="/tmp/supervisor-escalation-reply.consumed.$$"
  if mv /tmp/supervisor-escalation-reply "$_reply_tmp" 2>/dev/null; then
    ESCALATION_REPLY=$(cat "$_reply_tmp")
    rm -f "$_reply_tmp"
    log "Consumed escalation reply: $(echo "$ESCALATION_REPLY" | head -1)"
  fi
fi

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-supervisor.toml"
build_context_block AGENTS.md

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_prompt_footer

# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
PROMPT="You are the supervisor agent for ${CODEBERG_REPO}. Work through the formula below. You MUST write PHASE:done to '${PHASE_FILE}' when finished — the orchestrator will time you out if you return to the prompt without signalling.

You have full shell access and --dangerously-skip-permissions.
Fix what you can. Escalate what you cannot. Do NOT ask permission — act first, report after.

## Pre-flight metrics (collected $(date -u +%H:%M) UTC)
${PREFLIGHT_OUTPUT}
${ESCALATION_REPLY:+
## Escalation Reply (from Matrix — human message)
${ESCALATION_REPLY}

Act on this reply in the decide-actions step.
}
## Project context
${CONTEXT_BLOCK}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
Priority order: P0 memory > P1 disk > P2 stopped > P3 degraded > P4 housekeeping

${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Run session ──────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"
run_formula_and_monitor "supervisor" 1200

# ── Cleanup scratch file on normal exit ──────────────────────────────────
# FINAL_PHASE already set by run_formula_and_monitor
if [ "${FINAL_PHASE:-}" = "PHASE:done" ]; then
  rm -f "$SCRATCH_FILE"
fi
