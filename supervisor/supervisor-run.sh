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
#   4. Load formula (formulas/run-supervisor.toml)
#   5. Context: AGENTS.md, preflight metrics, structural graph
#   6. agent_run(worktree, prompt) → Claude monitors, may clean up
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

# ── WP Agent Health Recovery ──────────────────────────────────────────────
# Check preflight output for WP agent health issues and trigger recovery if needed
_WP_HEALTH_CHECK_FILE="${DISINTO_LOG_DIR}/supervisor/wp-agent-health-check.md"
echo "$PREFLIGHT_OUTPUT" > "$_WP_HEALTH_CHECK_FILE"

# Extract WP agent health status from preflight output
# Note: match exact "healthy" not "UNHEALTHY" (substring issue)
_wp_agent_healthy=$(grep "^WP Agent Health: healthy$" "$_WP_HEALTH_CHECK_FILE" 2>/dev/null && echo "true" || echo "false")
_wp_health_reason=$(grep "^Reason:" "$_WP_HEALTH_CHECK_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "")

if [ "$_wp_agent_healthy" = "false" ] && [ -n "$_wp_health_reason" ]; then
  log "WP agent detected as UNHEALTHY: $_wp_health_reason"

  # Check for idempotency guard - have we already restarted in this run?
  _WP_HEALTH_HISTORY_FILE="${DISINTO_LOG_DIR}/supervisor/wp-agent-health.history"
  _wp_last_restart_ts=0
  _wp_last_restart="never"
  if [ -f "$_WP_HEALTH_HISTORY_FILE" ]; then
    _wp_last_restart_ts=$(grep -m1 '^LAST_RESTART_TS=' "$_WP_HEALTH_HISTORY_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    if [ -n "$_wp_last_restart_ts" ] && [ "$_wp_last_restart_ts" != "0" ] 2>/dev/null; then
      _wp_last_restart=$(date -d "@$_wp_last_restart_ts" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$_wp_last_restart_ts")
    fi
  fi

  _current_ts=$(date +%s)
  _restart_threshold=300  # 5 minutes between restarts

  if [ -z "$_wp_last_restart_ts" ] || [ "$_wp_last_restart_ts" = "0" ] || [ $((_current_ts - _wp_last_restart_ts)) -gt $_restart_threshold ]; then
    log "Triggering WP agent restart..."

    # Restart the WP agent container
    if docker restart "$WP_AGENT_CONTAINER_NAME" >/dev/null 2>&1; then
      _restart_time=$(date -u '+%Y-%m-%d %H:%M UTC')
      log "Successfully restarted WP agent container: $WP_AGENT_CONTAINER_NAME"

      # Update history file
      echo "LAST_RESTART_TS=$_current_ts" > "$_WP_HEALTH_HISTORY_FILE"
      echo "LAST_RESTART_TIME=$_restart_time" >> "$_WP_HEALTH_HISTORY_FILE"

      # Post recovery notice to journal
      _journal_file="${OPS_JOURNAL_ROOT}/$(date -u +%Y-%m-%d).md"
      if [ -f "$_journal_file" ]; then
        {
          echo ""
          echo "### WP Agent Recovery - $_restart_time"
          echo ""
          echo "WP agent was unhealthy: $_wp_health_reason"
          echo "Container restarted automatically."
        } >> "$_journal_file"
      fi

      # Scan for issues updated in the last 30 minutes with blocked: ci_exhausted label
      log "Scanning for ci_exhausted issues updated in last 30 minutes..."
      _now_epoch=$(date +%s)
      _thirty_min_ago=$(( _now_epoch - 1800 ))

      # Fetch open issues with blocked label
      _blocked_issues=$(forge_api GET "/issues?state=open&labels=blocked&type=issues&limit=100" 2>/dev/null || echo "[]")
      _blocked_count=$(echo "$_blocked_issues" | jq 'length' 2>/dev/null || echo "0")

      _issues_processed=0
      _issues_recovered=0

      if [ "$_blocked_count" -gt 0 ]; then
        # Process each blocked issue
        echo "$_blocked_issues" | jq -c '.[]' 2>/dev/null | while IFS= read -r issue_json; do
          [ -z "$issue_json" ] && continue

          _issue_num=$(echo "$issue_json" | jq -r '.number // empty')
          _issue_updated=$(echo "$issue_json" | jq -r '.updated_at // empty')
          _issue_labels=$(echo "$issue_json" | jq -r '.labels | map(.name) | join(",")' 2>/dev/null || echo "")

          # Check if issue has ci_exhausted label
          if ! echo "$_issue_labels" | grep -q "ci_exhausted"; then
            continue
          fi

          # Parse updated_at timestamp
          _issue_updated_epoch=$(date -d "$_issue_updated" +%s 2>/dev/null || echo "0")
          _time_since_update=$(( _now_epoch - _issue_updated_epoch ))

          # Check if updated in last 30 minutes
          if [ "$_time_since_update" -lt 1800 ] && [ "$_time_since_update" -ge 0 ]; then
            _issues_processed=$(( _issues_processed + 1 ))

            # Check for idempotency guard - already swept by supervisor?
            _issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
            if echo "$_issue_body" | grep -q "<!-- supervisor-swept -->"; then
              log "Issue #$_issue_num already swept by supervisor, skipping"
              continue
            fi

            log "Processing ci_exhausted issue #$_issue_num (updated $_time_since_update seconds ago)"

            # Get issue assignee
            _issue_assignee=$(echo "$issue_json" | jq -r '.assignee.login // empty' 2>/dev/null || echo "")

            # Unassign the issue
            if [ -n "$_issue_assignee" ]; then
              log "Unassigning issue #$_issue_num from $_issue_assignee"
              curl -sf -X PATCH \
                -H "Authorization: token ${FORGE_SUPERVISOR_TOKEN:-$FORGE_TOKEN}" \
                -H "Content-Type: application/json" \
                "${FORGE_API}/issues/$_issue_num" \
                -d '{"assignees":[]}' >/dev/null 2>&1 || true
            fi

            # Remove blocked label
            _blocked_label_id=$(forge_api GET "/labels" 2>/dev/null | jq -r '.[] | select(.name == "blocked") | .id' 2>/dev/null || echo "")
            if [ -n "$_blocked_label_id" ]; then
              log "Removing blocked label from issue #$_issue_num"
              curl -sf -X DELETE \
                -H "Authorization: token ${FORGE_SUPERVISOR_TOKEN:-$FORGE_TOKEN}" \
                "${FORGE_API}/issues/$_issue_num/labels/$_blocked_label_id" >/dev/null 2>&1 || true
            fi

            # Add comment about infra-flake recovery
            _recovery_comment=$(cat <<EOF
<!-- supervisor-swept -->

**Automated Recovery — $(date -u '+%Y-%m-%d %H:%M UTC')**

CI agent was unhealthy between $_restart_time and now. The prior retry budget may have been spent on infra flake, not real failures.

**Recovery Actions:**
- Unassigned from pool and returned for fresh attempt
- CI agent container restarted
- Related pipelines will be retriggered automatically

**Next Steps:**
Please re-attempt this issue. The CI environment has been refreshed.
EOF
)

            curl -sf -X POST \
              -H "Authorization: token ${FORGE_SUPERVISOR_TOKEN:-$FORGE_TOKEN}" \
              -H "Content-Type: application/json" \
              "${FORGE_API}/issues/$_issue_num/comments" \
              -d "$(jq -n --arg body "$_recovery_comment" '{body: $body}')" >/dev/null 2>&1 || true

            log "Recovered issue #$_issue_num - returned to pool"
          fi
        done
      fi

      log "WP agent restart and issue recovery complete"
    else
      log "ERROR: Failed to restart WP agent container"
    fi
  else
    log "WP agent restart already performed in this run (since $_wp_last_restart), skipping"
  fi
fi

# ── Evaluate recipes for abnormal signals ──────────────────────────────────
# Run evaluate-recipes.sh to detect P0-P2 conditions; inject into prompt
RECIPE_OUTPUT=""
if [ -f "$FACTORY_ROOT/supervisor/recipes.yaml" ]; then
  RECIPE_OUTPUT=$(bash "$SCRIPT_DIR/evaluate-recipes.sh" \
    "$FACTORY_ROOT/supervisor/recipes.yaml" \
    <(echo "$PREFLIGHT_OUTPUT") 2>/dev/null) || true
fi

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
