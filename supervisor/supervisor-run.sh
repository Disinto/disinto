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
#   4a. Repair tape (#1408): one repair proposal per newly fired condition
#       (fired recipes, open CI incident PR); a condition that a later
#       preflight shows cleared earns an outcome with
#       bits {"regression_cleared":1}
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
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh"
# shellcheck source=../lib/tape.sh
source "$FACTORY_ROOT/lib/tape.sh"

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

# ── CI Circuit Breaker (issue #557) ─────────────────────────────────────
# Reconcile .dev-active against incident PR state each cycle.
# Open incident PR → remove .dev-active (pause dev agents).
# No open incident PR + green main → ensure .dev-active present (resume).
# Fail-safe: a missed cycle leaves trigger in last known state.
CI_UNTRUSTED=false
INCIDENT_PR=""

# Step 1: Check for existing open incident PRs
# Note: _ci_incident_pr_exists uses the Forge API (FORGE_API_BASE), not OPS_REPO_ROOT,
# so no guard here — the detection path must run in all modes for consistency.
INCIDENT_PR=$(_ci_incident_pr_exists 2>/dev/null) || true

if [ -n "$INCIDENT_PR" ]; then
  # Open incident PR exists — pause dev agents
  CI_UNTRUSTED=true
  DEV_ACTIVE="${FACTORY_ROOT}/state/.dev-active"
  if [ -f "$DEV_ACTIVE" ]; then
    rm -f "$DEV_ACTIVE"
    log "CI circuit breaker: open incident PR #${INCIDENT_PR} — removed .dev-active (pause dev agents)"
  fi
else
  # No open incident PR — check main canary for recovery
  CANARY_RESULT=$(ci_main_canary 2>/dev/null) || true
  if [ -n "$CANARY_RESULT" ]; then
    # Main canary red — create incident PR
    PIPES_JSON=$(ci_get_main_pipelines 2>/dev/null) || PIPES_JSON="[]"
    NEW_PR=$(create_incident_pr "$CANARY_RESULT" "$PIPES_JSON" 2>/dev/null) || true
    if [ -n "$NEW_PR" ]; then
      CI_UNTRUSTED=true
      INCIDENT_PR="$NEW_PR"
      DEV_ACTIVE="${FACTORY_ROOT}/state/.dev-active"
      if [ -f "$DEV_ACTIVE" ]; then
        rm -f "$DEV_ACTIVE"
        log "CI circuit breaker: canary red — created incident PR #${INCIDENT_PR}, removed .dev-active"
      fi
    fi
  else
    # Main canary green — check for recovery: close any incident PR
    # that was previously open (the main pipeline going green signals recovery)
    _ci_recover_incident_pr || true
    DEV_ACTIVE="${FACTORY_ROOT}/state/.dev-active"
    if [ ! -f "$DEV_ACTIVE" ]; then
      touch "$DEV_ACTIVE"
      log "CI circuit breaker: main green — restored .dev-active (resume dev agents)"
    fi
  fi
fi

# Export CI_UNTRUSTED for downstream use (e.g., recipe evaluation)
export CI_UNTRUSTED
# shellcheck disable=SC2034  # available for recipe evaluation
CI_INCIDENT_PR="${INCIDENT_PR:-}"

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

# ── Repair tape (#1408) ───────────────────────────────────────────────────
# Every condition the supervisor fires on — a recipe whose action this run
# is about to execute, or the CI circuit breaker (an incident PR is open) —
# gets ONE repair proposal on the tape when it first fires (loop="repair",
# class=<recipe name or "incident">, caused_by=<condition identifier>,
# context={"signature":<label>,"organ":"supervisor"}). When a later
# preflight no longer shows the condition, the open proposal earns one
# outcome with bits {"regression_cleared":1}. All labels are code-derived
# (recipe names, condition identifiers) — no LLM input. Every emitter is
# total: a tape failure logs a WARNING and returns 0, so the tape never
# blocks the supervisor.

# repair_tape_state_file — per-project state file (JSON object:
# condition → {proposal_id, class, since}) tracking which conditions
# currently have an open repair proposal. Override with
# SUPERVISOR_REPAIR_STATE_FILE (tests).
repair_tape_state_file() {
  if [ -n "${SUPERVISOR_REPAIR_STATE_FILE:-}" ]; then
    printf '%s\n' "$SUPERVISOR_REPAIR_STATE_FILE"
  else
    printf '%s/state/supervisor-repairs-%s.json' \
      "${FACTORY_ROOT:-.}" "${PROJECT_NAME:-default}"
  fi
}

# repair_conditions_current_json — the condition identifiers firing this
# tick as a JSON array: every fired recipe name (straight out of
# evaluate-recipes.sh) plus "ci-incident-pr" while the CI circuit breaker
# is open. Code-derived only — no LLM input.
repair_conditions_current_json() {
  local ci_cond="" recipe_names=""
  if [ "${CI_UNTRUSTED:-false}" = "true" ]; then
    ci_cond="ci-incident-pr"
  fi
  if [ -n "${RECIPE_OUTPUT:-}" ]; then
    recipe_names="$(printf '%s' "$RECIPE_OUTPUT" \
      | jq -r '(.fired // [])[] | .name // empty' 2>/dev/null)" \
      || recipe_names=""
  fi
  jq -cn --arg ci "$ci_cond" --arg recipes "$recipe_names" '
    (if $ci != "" then [$ci] else [] end)
    + ($recipes | split("\n") | map(select(length > 0)))'
}

# _repair_state_update JQ_EXPR — atomically rewrite the repair state file
# by applying JQ_EXPR to the current state object ({} when the file is
# missing or holds a non-object, so a torn line can never crash a tick).
# Total: warns and returns 0 on any failure.
_repair_state_update() {
  local expr="$1" state_file cur next tmp
  state_file="$(repair_tape_state_file)"
  cur="$(cat "$state_file" 2>/dev/null)" || cur="{}"
  if ! printf '%s' "$cur" | jq -e 'type == "object"' >/dev/null 2>&1; then
    cur="{}"
  fi
  if ! next="$(printf '%s' "$cur" | jq -c "$expr" 2>/dev/null)"; then
    log "WARNING: tape: failed to update repair state ${state_file}"
    return 0
  fi
  tmp="${state_file}.tmp.$$"
  if ! mkdir -p "$(dirname "$state_file")" 2>/dev/null \
    || ! printf '%s\n' "$next" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$state_file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    log "WARNING: tape: failed to update repair state ${state_file}"
    return 0
  fi
  return 0
}

# repair_state_put CONDITION PROPOSAL_ID [CLASS] — record an open repair
# condition so a later tick whose preflight shows it cleared can emit the
# matched outcome. Total: warns and returns 0 on any failure.
repair_state_put() {
  local condition="${1:-}" proposal_id="${2:-}" class="${3:-incident}" entry
  if [ -z "$condition" ] || [ -z "$proposal_id" ]; then
    return 0
  fi
  case "$condition" in
    *[!A-Za-z0-9._-]*)
      log "WARNING: tape: refusing unsafe condition identifier '${condition}' (state update skipped)"
      return 0
      ;;
  esac
  if ! entry="$(jq -cn --arg p "$proposal_id" --arg k "$class" \
      --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{proposal_id: $p, class: $k, since: $t}')" || [ -z "$entry" ]; then
    log "WARNING: tape: failed to build state entry for ${condition}"
    return 0
  fi
  _repair_state_update "{ \"${condition}\": ${entry} } + ."
  return 0
}

# emit_repair_proposal CONDITION [CLASS] [REF] — append one repair
# proposal to the tape (loop="repair") and register the condition in the
# state file for the cleared-outcome pairing. Total: warns and returns 0
# on any failure — a failed tape append also skips the state write, so the
# next tick retries the proposal.
emit_repair_proposal() {
  local condition="${1:-}" class="${2:-}" ref="${3:-}" id ctx
  if [ -z "$condition" ]; then
    log "WARNING: tape: no condition identifier — skipping repair proposal"
    return 0
  fi
  [ -n "$class" ] || class="incident"
  [ -n "$ref" ] || ref="$condition"

  id="$(formula_tape_ulid 2>/dev/null)" || id=""
  [ -n "$id" ] || id="repair-$(date -u +%Y%m%d%H%M%S)-$$"

  if ! ctx="$(jq -cn --arg sig "$condition" --arg organ "supervisor" \
      '{signature: $sig, organ: $organ}')" || [ -z "$ctx" ]; then
    log "WARNING: tape: failed to build context for ${condition}"
    return 0
  fi

  if ! tape_proposal "$id" repair "$class" "" "$condition" "$ctx" "" \
      "auto" "$ref" >/dev/null 2>&1; then
    log "WARNING: tape: failed to append repair proposal ${id} (${condition})"
    return 0
  fi

  repair_state_put "$condition" "$id" "$class"
  log "tape: recorded repair proposal ${id} (class: ${class}, condition: ${condition})"
  return 0
}

# repair_tape_tick — one repair-tape pass per supervisor tick, called after
# recipe evaluation and before the LLM escalation gate so both the fast
# path and the LLM path are covered: a condition firing this tick with no
# open repair record gets one repair proposal; a recorded condition no
# longer firing (a later preflight shows the condition cleared) gets one
# outcome with bits {"regression_cleared":1} and drops out of the state
# file. Total: always returns 0 — the tape never blocks the supervisor.
repair_tape_tick() {
  local state_file prev_json cur_json new_list cleared_list
  state_file="$(repair_tape_state_file)"
  cur_json="$(repair_conditions_current_json)" || cur_json="[]"
  [ -n "$cur_json" ] || cur_json="[]"

  prev_json="$(cat "$state_file" 2>/dev/null)" || prev_json="{}"
  if ! printf '%s' "$prev_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    prev_json="{}"
  fi

  new_list="$(jq -rn --argjson cur "$cur_json" --argjson prev "$prev_json" '
      $cur[] | select(. as $c | ($prev | has($c)) | not)')" || new_list=""
  cleared_list="$(jq -rn --argjson cur "$cur_json" --argjson prev "$prev_json" '
      ($prev | keys[]) | select(. as $c | ($cur | index($c)) == null)')" \
    || cleared_list=""

  local cond class
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    if [ "$cond" = "ci-incident-pr" ]; then
      if [ -n "${INCIDENT_PR:-}" ]; then
        emit_repair_proposal "ci-incident-pr" "incident" "incident-pr-${INCIDENT_PR}"
      else
        emit_repair_proposal "ci-incident-pr" "incident"
      fi
    else
      emit_repair_proposal "$cond" "$cond"
    fi
  done <<< "$new_list"

  local proposal_id
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    proposal_id="$(printf '%s' "$prev_json" \
      | jq -r --arg c "$cond" '.[$c].proposal_id // empty' 2>/dev/null)" \
      || proposal_id=""
    if [ -z "$proposal_id" ]; then
      log "WARNING: tape: no proposal id recorded for cleared condition ${cond}"
      continue
    fi
    if ! tape_outcome "$proposal_id" '{"regression_cleared":1}' '{}' '{}' '[]' \
        >/dev/null 2>&1; then
      log "WARNING: tape: failed to append cleared outcome for ${cond} (${proposal_id})"
    else
      log "tape: condition ${cond} cleared — outcome recorded for ${proposal_id}"
    fi
  done <<< "$cleared_list"

  # Drop the cleared conditions from the state file (tape records are
  # immutable; the state file only tracks open regressions).
  local keys_json="[]" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    keys_json="$(jq -c --arg key "$k" '. + [$key]' <<< "$keys_json")" \
      || keys_json="[]"
  done <<< "$cleared_list"
  if [ "$keys_json" != "[]" ]; then
    _repair_state_update \
      "with_entries(select(.key as \$k | ${keys_json} | index(\$k) | not))"
  fi
  return 0
}

# One pass per tick — covers both the fast path and the LLM path (#1408).
repair_tape_tick

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

  # ── Execute direct-action scripts for all fired direct recipes ──────
  # This is the dispatch loop that runs remediation scripts before the
  # fast-path exit. Without it, direct-action scripts are dead code.
  # Passes PROJECT_TOML + evidence (health reason for wp-agent-restart.sh).
  if [ -n "$RECIPE_OUTPUT" ]; then
    while IFS=$'\t' read -r _script _evidence; do
      if [ -n "$_script" ] && [ "$_script" != "__MISSING__" ]; then
        bash "$FACTORY_ROOT/$_script" "$PROJECT_TOML" "$_evidence" || true
      fi
    done < <(printf '%s' "$RECIPE_OUTPUT" | jq -r '.fired[] | select(.action == "direct") | [.action_script, .evidence // empty] | @tsv' 2>/dev/null)
  fi

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
# Open the proposal-loop tape run record (#1391) — total, never fails us
formula_session_start "supervisor"

# Guarded: a resource-limit exit (rc 124 = wall-clock timeout) must not abort
# the script under set -e — record the rc and continue (#1164).
SUPERVISOR_RUN_RC=0
agent_run --worktree "$WORKTREE" "$PROMPT" || SUPERVISOR_RUN_RC=$?
[ "$SUPERVISOR_RUN_RC" -eq 0 ] || log "supervisor agent_run exited ${SUPERVISOR_RUN_RC} (124 = wall-clock timeout) — continuing"
log "agent_run complete"

# Close the tape run: outcome + closing run record (#1391)
formula_session_end "$SUPERVISOR_RUN_RC"

# Write journal entry post-session
profile_write_journal "supervisor-run" "Supervisor run $(date -u +%Y-%m-%d)" "complete" "" || true

# Commit and push any incident files written during this tick
if [ -n "${OPS_REPO_ROOT:-}" ] && [ -d "${OPS_REPO_ROOT}/incidents" ]; then
  bash "$SCRIPT_DIR/commit-incidents.sh" || true
fi

rm -f "$SCRATCH_FILE"
log "--- Supervisor run done ---"
