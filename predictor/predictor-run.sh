#!/usr/bin/env bash
# =============================================================================
# predictor-run.sh — Cron wrapper: predictor execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: cron lock, memory check
#   2. Load formula (formulas/run-predictor.toml)
#   3. Context: AGENTS.md, ops:RESOURCES.md, VISION.md, structural graph
#   4. agent_run(worktree, prompt) → Claude analyzes, writes to ops repo
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
# Use predictor-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_PREDICTOR_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="$SCRIPT_DIR/predictor.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/predictor-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/predictor-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-predictor-run"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active predictor
acquire_cron_lock "/tmp/predictor-run.lock"
check_memory 2000

log "--- Predictor run start ---"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-predictor.toml"
build_context_block AGENTS.md ops:RESOURCES.md VISION.md ops:prerequisites.md

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer
export CLAUDE_MODEL="sonnet"

PROMPT="You are the prediction agent (goblin) for ${FORGE_REPO}. Work through the formula below.

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
${GRAPH_SECTION}
${SCRATCH_CONTEXT}
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Create worktree ──────────────────────────────────────────────────────
formula_worktree_setup "$WORKTREE"

# ── Run agent ─────────────────────────────────────────────────────────────
agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

rm -f "$SCRATCH_FILE"
log "--- Predictor run done ---"
