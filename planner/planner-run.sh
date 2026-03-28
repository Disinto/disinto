#!/usr/bin/env bash
# =============================================================================
# planner-run.sh — Cron wrapper: planner execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: cron lock, memory check
#   2. Load formula (formulas/run-planner.toml)
#   3. Context: VISION.md, AGENTS.md, ops:RESOURCES.md, structural graph,
#      planner memory, journal entries
#   4. agent_run(worktree, prompt) → Claude plans, may push knowledge updates
#
# Usage:
#   planner-run.sh [projects/disinto.toml]   # project config (default: disinto)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto (planner is disinto infrastructure)
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# Use planner-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_PLANNER_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="$SCRIPT_DIR/planner.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/planner-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/planner-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-planner-run"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active planner
acquire_cron_lock "/tmp/planner-run.lock"
check_memory 2000

log "--- Planner run start ---"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-planner.toml"
build_context_block VISION.md AGENTS.md ops:RESOURCES.md ops:prerequisites.md

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section

# ── Ensure ops repo is available ───────────────────────────────────────
ensure_ops_repo

# ── Read planner memory ─────────────────────────────────────────────────
MEMORY_BLOCK=""
MEMORY_FILE="$OPS_REPO_ROOT/knowledge/planner-memory.md"
if [ -f "$MEMORY_FILE" ]; then
  MEMORY_BLOCK="
### knowledge/planner-memory.md (persistent memory from prior runs)
$(cat "$MEMORY_FILE")
"
fi

# ── Read recent journal files ──────────────────────────────────────────
JOURNAL_BLOCK=""
JOURNAL_DIR="$OPS_REPO_ROOT/journal/planner"
if [ -d "$JOURNAL_DIR" ]; then
  # Load last 5 journal files (most recent first) for run history context
  JOURNAL_FILES=$(find "$JOURNAL_DIR" -name '*.md' -type f | sort -r | head -5)
  if [ -n "$JOURNAL_FILES" ]; then
    JOURNAL_BLOCK="
### Recent journal entries (journal/planner/)
"
    while IFS= read -r jf; do
      JOURNAL_BLOCK="${JOURNAL_BLOCK}
#### $(basename "$jf")
$(cat "$jf")
"
    done <<< "$JOURNAL_FILES"
  fi
fi

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer "
  Relabel:     curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X PUT -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}/labels' -d '{\"labels\":[LABEL_ID]}'
  Comment:     curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X POST -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'
  Close:       curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X PATCH -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}' -d '{\"state\":\"closed\"}'
"

PROMPT="You are the strategic planner for ${FORGE_REPO}. Work through the formula below.

## Project context
${CONTEXT_BLOCK}${MEMORY_BLOCK}${JOURNAL_BLOCK}
${GRAPH_SECTION}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}

${PROMPT_FOOTER}"

# ── Create worktree ──────────────────────────────────────────────────────
formula_worktree_setup "$WORKTREE"

# ── Run agent ─────────────────────────────────────────────────────────────
export CLAUDE_MODEL="opus"

agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

rm -f "$SCRATCH_FILE"
log "--- Planner run done ---"
