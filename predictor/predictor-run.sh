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
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"

LOG_FILE="$SCRIPT_DIR/predictor.log"
# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
SESSION_NAME="predictor-${PROJECT_NAME}"
PHASE_FILE="/tmp/predictor-session-${PROJECT_NAME}.phase"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

SCRATCH_FILE="/tmp/predictor-${PROJECT_NAME}-scratch.md"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active predictor
acquire_cron_lock "/tmp/predictor-run.lock"
check_memory 2000

log "--- Predictor run start ---"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-predictor.toml"
build_context_block AGENTS.md RESOURCES.md VISION.md planner/prerequisite-tree.md

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_prompt_footer

# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
PROMPT="You are the prediction agent (goblin) for ${FORGE_REPO}. Work through the formula below. You MUST write PHASE:done to '${PHASE_FILE}' when finished — the orchestrator will time you out if you return to the prompt without signalling.

Your role: abstract adversary. Find the project's biggest weakness, challenge
planner claims, and generate evidence. Explore when uncertain (file a prediction),
exploit when confident (file a prediction AND dispatch a formula via an action issue).

Your prediction history IS your memory — review it to decide where to focus.
The planner (adult) will triage every prediction before acting.
You MUST NOT emit feature work or implementation issues — only predictions
challenging claims, exposing gaps, and surfacing risks.
Use WebSearch for external signal scanning — be targeted (project dependencies
and tools only, not general news). Limit to 3 web searches per run.

## Project context
${CONTEXT_BLOCK}
${SCRATCH_CONTEXT}
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Run session ──────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"
run_formula_and_monitor "predictor"

# ── Cleanup scratch file on normal exit ──────────────────────────────────
# FINAL_PHASE already set by run_formula_and_monitor
if [ "${FINAL_PHASE:-}" = "PHASE:done" ]; then
  rm -f "$SCRATCH_FILE"
fi
