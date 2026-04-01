#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Cron wrapper: architect execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: cron lock, memory check
#   2. Load formula (formulas/run-architect.toml)
#   3. Context: VISION.md, AGENTS.md, ops:prerequisites.md, structural graph
#   4. agent_run(worktree, prompt) → Claude decomposes vision into sprints
#
# Usage:
#   architect-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Cron: 0 */6 * * *   # every 6 hours
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# Override FORGE_TOKEN with architect-bot's token (#747)
FORGE_TOKEN="${FORGE_ARCHITECT_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="$SCRIPT_DIR/architect.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/architect-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/architect-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-architect-run"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active architect
acquire_cron_lock "/tmp/architect-run.lock"
check_memory 2000

log "--- Architect run start ---"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-architect.toml"
build_context_block VISION.md AGENTS.md ops:prerequisites.md

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer

# Architect prompt: strategic decomposition of vision into sprints
# See: architect/AGENTS.md for full role description
# Pattern: heredoc function to avoid inline prompt construction
# Note: Uses CONTEXT_BLOCK, GRAPH_SECTION, SCRATCH_CONTEXT from formula-session.sh
# Architecture Decision: AD-003 — The runtime creates and destroys, the formula preserves.
build_architect_prompt() {
  cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

Your role: strategic decomposition of vision issues into development sprints.
Propose sprints via PRs on the ops repo, converse with humans through PR comments,
and file sub-issues after design forks are resolved.

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
${SCRATCH_CONTEXT}
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}
_PROMPT_EOF_
}

PROMPT=$(build_architect_prompt)

# ── Create worktree ──────────────────────────────────────────────────────
formula_worktree_setup "$WORKTREE"

# ── Run agent ─────────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"

agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

rm -f "$SCRATCH_FILE"
log "--- Architect run done ---"
