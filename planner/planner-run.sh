#!/usr/bin/env bash
# =============================================================================
# planner-run.sh — Polling-loop wrapper: planner execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: run lock, memory check
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

LOG_FILE="${DISINTO_LOG_DIR}/planner/planner.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/planner-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/planner-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-planner-run"

# Override LOG_AGENT for consistent agent identification
# shellcheck disable=SC2034  # consumed by agent-sdk.sh and env.sh log()
LOG_AGENT="planner"

# Override log() to append to planner-specific log file
# shellcheck disable=SC2034
log() {
  local agent="${LOG_AGENT:-planner}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active planner
acquire_run_lock "/tmp/planner-run.lock"
memory_guard 2000

log "--- Planner run start ---"

# ── Precondition checks: skip if nothing to plan ──────────────────────────
LAST_SHA_FILE="$FACTORY_ROOT/state/planner-last-sha"
LAST_OPS_SHA_FILE="$FACTORY_ROOT/state/planner-last-ops-sha"

CURRENT_SHA=$(git -C "$FACTORY_ROOT" rev-parse HEAD 2>/dev/null || echo "")
LAST_SHA=$(cat "$LAST_SHA_FILE" 2>/dev/null || echo "")

# ops repo is required for planner — pull before checking sha
ensure_ops_repo
CURRENT_OPS_SHA=$(git -C "$OPS_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
LAST_OPS_SHA=$(cat "$LAST_OPS_SHA_FILE" 2>/dev/null || echo "")

unreviewed_count=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues?labels=prediction/unreviewed&state=open&limit=1" 2>/dev/null | jq length) || unreviewed_count=0
vision_open=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues?labels=vision&state=open&limit=1" 2>/dev/null | jq length) || vision_open=0

if [ "$CURRENT_SHA" = "$LAST_SHA" ] \
   && [ "$CURRENT_OPS_SHA" = "$LAST_OPS_SHA" ] \
   && [ "${unreviewed_count:-0}" -eq 0 ] \
   && [ "${vision_open:-0}" -eq 0 ]; then
  log "no new commits, no ops changes, no unreviewed predictions, no open vision — skipping"
  exit 0
fi

log "sha=${CURRENT_SHA:0:8} ops=${CURRENT_OPS_SHA:0:8} unreviewed=${unreviewed_count} vision=${vision_open}"

# ── Resolve forge remote for git operations ─────────────────────────────
# Run git operations from the project checkout, not the baked code dir
cd "$PROJECT_REPO_ROOT"

resolve_forge_remote

# ── Resolve agent identity for .profile repo ────────────────────────────
resolve_agent_identity || true

# ── Load formula + context ───────────────────────────────────────────────
load_formula_or_profile "planner" "$FACTORY_ROOT/formulas/run-planner.toml" || exit 1
build_context_block VISION.md AGENTS.md ops:RESOURCES.md ops:prerequisites.md

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section

# ── Read planner memory ─────────────────────────────────────────────────
MEMORY_BLOCK=""
MEMORY_FILE="$OPS_REPO_ROOT/knowledge/planner-memory.md"
if [ -f "$MEMORY_FILE" ]; then
  MEMORY_BLOCK="
### knowledge/planner-memory.md (persistent memory from prior runs)
$(cat "$MEMORY_FILE")
"
fi

# ── Prepare .profile context (lessons injection) ─────────────────────────
formula_prepare_profile_context

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
${CONTEXT_BLOCK}${MEMORY_BLOCK}$(formula_lessons_block)
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

# Persist watermarks so next run can skip if nothing changed
mkdir -p "$FACTORY_ROOT/state"
echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
echo "$CURRENT_OPS_SHA" > "$LAST_OPS_SHA_FILE"

# Write journal entry post-session
profile_write_journal "planner-run" "Planner run $(date -u +%Y-%m-%d)" "complete" "" || true

rm -f "$SCRATCH_FILE"
log "--- Planner run done ---"
