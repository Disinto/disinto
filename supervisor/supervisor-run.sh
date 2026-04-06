#!/usr/bin/env bash
# =============================================================================
# supervisor-run.sh — Cron wrapper: supervisor execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: cron lock, memory check
#   2. Housekeeping: clean up stale crashed worktrees
#   3. Collect pre-flight metrics (supervisor/preflight.sh)
#   4. Load formula (formulas/run-supervisor.toml)
#   5. Context: AGENTS.md, preflight metrics, structural graph
#   6. agent_run(worktree, prompt) → Claude monitors, may clean up
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
# Use supervisor-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_SUPERVISOR_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="$SCRIPT_DIR/supervisor.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/supervisor-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/supervisor-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-supervisor-run"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active supervisor
acquire_cron_lock "/tmp/supervisor-run.lock"
memory_guard 2000

log "--- Supervisor run start ---"

# ── Resolve forge remote for git operations ─────────────────────────────
resolve_forge_remote

# ── Housekeeping: clean up stale crashed worktrees (>24h) ────────────────
cleanup_stale_crashed_worktrees 24

# ── Resolve agent identity for .profile repo ────────────────────────────
resolve_agent_identity || true

# ── Collect pre-flight metrics ────────────────────────────────────────────
log "Running preflight.sh"
PREFLIGHT_OUTPUT=""
if PREFLIGHT_OUTPUT=$(bash "$SCRIPT_DIR/preflight.sh" "$PROJECT_TOML" 2>&1); then
  log "Preflight collected ($(echo "$PREFLIGHT_OUTPUT" | wc -l) lines)"
else
  log "WARNING: preflight.sh failed, continuing with partial data"
fi

# ── Load formula + context ───────────────────────────────────────────────
load_formula_or_profile "supervisor" "$FACTORY_ROOT/formulas/run-supervisor.toml" || exit 1
build_context_block AGENTS.md

# ── Prepare .profile context (lessons injection) ─────────────────────────
formula_prepare_profile_context

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer
export CLAUDE_MODEL="sonnet"

# ── Create worktree (before prompt assembly so trap is set early) ────────
formula_worktree_setup "$WORKTREE"

PROMPT="You are the supervisor agent for ${FORGE_REPO}. Work through the formula below.

You have full shell access and --dangerously-skip-permissions.
Fix what you can. File vault items for what you cannot. Do NOT ask permission — act first, report after.

## Pre-flight metrics (collected $(date -u +%H:%M) UTC)
${PREFLIGHT_OUTPUT}

## Project context
${CONTEXT_BLOCK}$(formula_lessons_block)
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
Priority order: P0 memory > P1 disk > P2 stopped > P3 degraded > P4 housekeeping

${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Run agent ─────────────────────────────────────────────────────────────
agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

# Write journal entry post-session
profile_write_journal "supervisor-run" "Supervisor run $(date -u +%Y-%m-%d)" "complete" "" || true

rm -f "$SCRATCH_FILE"
log "--- Supervisor run done ---"
