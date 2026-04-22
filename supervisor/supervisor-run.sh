#!/usr/bin/env bash
# =============================================================================
# supervisor-run.sh — Polling-loop wrapper: supervisor execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: run lock, memory check
#   2. Housekeeping: clean up stale crashed worktrees
#   3. Collect pre-flight metrics (supervisor/preflight.sh)
#   4. Evaluate recipes for abnormal signals (supervisor/evaluate-recipes.sh)
#   5. LLM escalation gate: skip claude -p when no abnormal signal (fast path)
#   6. Load formula (formulas/run-supervisor.toml)
#   7. Context: AGENTS.md, preflight metrics, structural graph
#   8. agent_run(worktree, prompt) → Claude monitors, may clean up
#
# Usage:
#   supervisor-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Called by: entrypoint.sh polling loop (every 20 minutes)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# Set override BEFORE sourcing env.sh so it survives any later re-source of
# env.sh from nested shells / claude -p tools (#762, #747)
export FORGE_TOKEN_OVERRIDE="${FORGE_SUPERVISOR_TOKEN:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="${DISINTO_LOG_DIR}/supervisor/supervisor.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/supervisor-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/supervisor-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-supervisor-run"

# WP agent container name (configurable via env var)
export WP_AGENT_CONTAINER_NAME="${WP_AGENT_CONTAINER_NAME:-disinto-woodpecker-agent}"

# Override LOG_AGENT for consistent agent identification
# shellcheck disable=SC2034  # consumed by agent-sdk.sh and env.sh log()
LOG_AGENT="supervisor"

# ── OPS Repo Detection (Issue #544) ──────────────────────────────────────
# Detect if OPS_REPO_ROOT is available and set degraded mode flag if not.
# This allows the supervisor to run with fallback knowledge files and
# local journal/vault paths when the ops repo is absent.
if [ -z "${OPS_REPO_ROOT:-}" ] || [ ! -d "${OPS_REPO_ROOT}" ]; then
  log "WARNING: OPS_REPO_ROOT not set or directory missing — running in degraded mode (no playbooks, no journal continuity, no vault destination)"
  export OPS_REPO_DEGRADED=1
  # Set fallback paths for degraded mode
  export OPS_KNOWLEDGE_ROOT="${FACTORY_ROOT}/knowledge"
  export OPS_JOURNAL_ROOT="${FACTORY_ROOT}/state/supervisor-journal"
  export OPS_VAULT_ROOT="${PROJECT_REPO_ROOT}/vault/pending"
  mkdir -p "$OPS_JOURNAL_ROOT" "$OPS_VAULT_ROOT" 2>/dev/null || true
else
  export OPS_REPO_DEGRADED=0
  export OPS_KNOWLEDGE_ROOT="${OPS_REPO_ROOT}/knowledge"
  export OPS_JOURNAL_ROOT="${OPS_REPO_ROOT}/journal/supervisor"
  export OPS_VAULT_ROOT="${OPS_REPO_ROOT}/vault/pending"
  mkdir -p "$OPS_JOURNAL_ROOT" "$OPS_VAULT_ROOT" 2>/dev/null || true
fi

# Override log() to append to supervisor-specific log file
# shellcheck disable=SC2034
log() {
  local agent="${LOG_AGENT:-supervisor}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active supervisor
acquire_run_lock "/tmp/supervisor-run.lock"
memory_guard 2000

log "--- Supervisor run start ---"

# ── Resolve forge remote for git operations ─────────────────────────────
# Run git operations from the project checkout, not the baked code dir
cd "$PROJECT_REPO_ROOT"

# ── Housekeeping: clean up stale crashed worktrees (>24h) ────────────────
cleanup_stale_crashed_worktrees 24

# ── Resolve agent identity for .profile repo ────────────────────────────
resolve_agent_identity || true

# ── Collect pre-flight metrics ────────────────────────────────────────────
log "Running preflight.sh"
PREFLIGHT_OUTPUT=""
PREFLIGHT_RC=0
if PREFLIGHT_OUTPUT=$(bash "$SCRIPT_DIR/preflight.sh" "$PROJECT_TOML" 2>&1); then
  log "Preflight collected ($(echo "$PREFLIGHT_OUTPUT" | wc -l) lines)"
else
  PREFLIGHT_RC=$?
  log "WARNING: preflight.sh failed (exit code $PREFLIGHT_RC), continuing with partial data"
  if [ -n "$PREFLIGHT_OUTPUT" ]; then
    log "Preflight error: $(echo "$PREFLIGHT_OUTPUT" | tail -3)"
  fi
fi

# ── Evaluate recipes for abnormal signals ──────────────────────────────────
# Run evaluate-recipes.sh to detect P0-P2 conditions.
# Output: {"fired":[{"name":"...","severity":"P1","evidence":"...","action":"direct|llm","action_script":"..."}]}
RECIPE_OUTPUT=""
if [ -f "$FACTORY_ROOT/supervisor/recipes.yaml" ]; then
  _eval_exit=0
  RECIPE_OUTPUT=$(bash "$SCRIPT_DIR/evaluate-recipes.sh" \
    "$FACTORY_ROOT/supervisor/recipes.yaml" \
    <(echo "$PREFLIGHT_OUTPUT") 2>/dev/null) || _eval_exit=$?
  if [ "$_eval_exit" -ne 0 ]; then
    log "WARNING: recipe evaluator exited $_eval_exit — falling back to always-LLM gate"
  fi
fi

# ── LLM escalation gate ───────────────────────────────────────────────────
# Fast path: no abnormal signals → skip LLM entirely.
# Only invoke claude -p when recipe evaluator fired at least one abnormal
# signal that requires LLM attention (action: llm, or action_script missing).
#
# This eliminates ~72 unnecessary opus calls per day on healthy boxes.
# See issue #593.
LLM_REQUIRED=true
if [ -n "$RECIPE_OUTPUT" ]; then
  _fired_count=$(printf '%s' "$RECIPE_OUTPUT" | jq -r '.fired | length' 2>/dev/null || echo "0")
  if [ "$_fired_count" -gt 0 ]; then
    # At least one recipe fired — check if any need LLM.
    # If all fires have action: direct AND a valid action_script, skip LLM
    # (direct-action handlers are wired in #594; until then, fall through).
    _llm_count=$(printf '%s' "$RECIPE_OUTPUT" | jq -r '[.fired[] | select(.action == "llm")] | length' 2>/dev/null || echo "0")
    _direct_ok_count=$(printf '%s' "$RECIPE_OUTPUT" | jq -r '[.fired[] | select(.action == "direct" and .action_script != "__MISSING__")] | length' 2>/dev/null || echo "0")
    _direct_total=$(printf '%s' "$RECIPE_OUTPUT" | jq -r '[.fired[] | select(.action == "direct")] | length' 2>/dev/null || echo "0")
    _has_non_direct=$(printf '%s' "$RECIPE_OUTPUT" | jq -r '[.fired[] | select(.action != "direct")] | length' 2>/dev/null || echo "0")

    if [ "$_llm_count" -gt 0 ]; then
      LLM_REQUIRED=true
    elif [ "$_direct_total" -gt 0 ] && [ "$_direct_total" -eq "$_direct_ok_count" ] && [ "$_has_non_direct" -eq 0 ]; then
      # All direct fires have valid action_script and no non-direct actions —
      # safe to skip LLM (direct-action dispatch is implemented in #594).
      log "All ${_direct_total} fired recipe(s) have direct-action handlers — skipping LLM (fast path)"
      LLM_REQUIRED=false
    else
      # Mixed: some direct fires lack action_script, or there are incident/vault/llm actions
      LLM_REQUIRED=true
    fi
  else
    # No recipes fired — healthy box, no LLM needed.
    LLM_REQUIRED=false
  fi
fi

if [ "$LLM_REQUIRED" = false ]; then
  log "No abnormal signals requiring LLM — fast path, skipping agent_run"
  # Write journal entry (brief "all clear" only if prior run had findings)
  profile_write_journal "supervisor-run" "Supervisor run $(date -u +%Y-%m-%d)" "complete" || true

  # Commit and push any incident files written during this tick
  if [ -n "${OPS_REPO_ROOT:-}" ] && [ -d "${OPS_REPO_ROOT}/incidents" ]; then
    bash "$SCRIPT_DIR/commit-incidents.sh" || true
  fi

  rm -f "$SCRATCH_FILE"
  log "--- Supervisor run done (fast path) ---"
  exit 0
fi

log "Abnormal signals detected — proceeding to LLM escalation path"

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

# Inject OPS repo status into prompt
if [ "${OPS_REPO_DEGRADED:-0}" = "1" ]; then
  OPS_STATUS="
## OPS Repo Status
**DEGRADED MODE**: OPS repo is not available. Using bundled knowledge files and local journal/vault paths.
- Knowledge files: ${OPS_KNOWLEDGE_ROOT:-<unset>}
- Journal: ${OPS_JOURNAL_ROOT:-<unset>}
- Vault destination: ${OPS_VAULT_ROOT:-<unset>}
"
else
  OPS_STATUS="
## OPS Repo Status
**FULL MODE**: OPS repo available at ${OPS_REPO_ROOT}
- Knowledge files: ${OPS_KNOWLEDGE_ROOT:-<unset>}
- Journal: ${OPS_JOURNAL_ROOT:-<unset>}
- Vault destination: ${OPS_VAULT_ROOT:-<unset>}
"
fi

PROMPT="You are the supervisor agent for ${FORGE_REPO}. Work through the formula below.

You have full shell access and --dangerously-skip-permissions.
Fix what you can. File vault items for what you cannot. Do NOT ask permission — act first, report after.

## Pre-flight metrics (collected $(date -u +%H:%M) UTC)
${PREFLIGHT_OUTPUT}

## Recipe evaluation (abnormal-signal detection)
${RECIPE_OUTPUT:-(no recipes fired)}

## Project context
${CONTEXT_BLOCK}$(formula_lessons_block)
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
${OPS_STATUS}
Priority order: P0 memory > P1 disk > P2 stopped > P3 degraded > P4 housekeeping

${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Run agent ─────────────────────────────────────────────────────────────
agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

# Write journal entry post-session
profile_write_journal "supervisor-run" "Supervisor run $(date -u +%Y-%m-%d)" "complete" "" || true

# Commit and push any incident files written during this tick
if [ -n "${OPS_REPO_ROOT:-}" ] && [ -d "${OPS_REPO_ROOT}/incidents" ]; then
  bash "$SCRIPT_DIR/commit-incidents.sh" || true
fi

rm -f "$SCRATCH_FILE"
log "--- Supervisor run done ---"
