#!/usr/bin/env bash
# supervisor/actions/wp-agent-restart.sh — P2 Woodpecker agent recovery
#
# Detects unhealthy WP agent, restarts container (5-min cooldown), then scans
# for ci_exhausted issues updated in the last 30 minutes and recovers them.
#
# Sources: lib/env.sh (log, forge_api), supervisor/supervisor-run.sh (original
# recovery logic, lines 244-396).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
export FORGE_TOKEN_OVERRIDE="${FORGE_SUPERVISOR_TOKEN:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

# WP agent container name (configurable via env var)
export WP_AGENT_CONTAINER_NAME="${WP_AGENT_CONTAINER_NAME:-disinto-woodpecker-agent}"

# ── OPS Repo Detection (mirrors supervisor-run.sh) ─────────────────────
if [ -z "${OPS_REPO_ROOT:-}" ] || [ ! -d "${OPS_REPO_ROOT}" ]; then
  export OPS_REPO_DEGRADED=1
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
log() {
  local agent="${LOG_AGENT:-supervisor}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

LOG_FILE="${DISINTO_LOG_DIR}/supervisor/supervisor.log"
LOG_AGENT="supervisor"

# ── WP Agent Health Check ───────────────────────────────────────────────
_WP_HEALTH_CHECK_FILE="${DISINTO_LOG_DIR}/supervisor/wp-agent-health-check.md"

# Extract WP agent health status
_wp_agent_healthy=$(grep "^WP Agent Health: healthy$" "$_WP_HEALTH_CHECK_FILE" 2>/dev/null && echo "true" || echo "false")
_wp_health_reason=$(grep "^Reason:" "$_WP_HEALTH_CHECK_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "")

if [ "$_wp_agent_healthy" = "false" ] && [ -n "$_wp_health_reason" ]; then
  log "WP agent detected as UNHEALTHY: $_wp_health_reason"

  # ── Idempotency guard: 5-minute cooldown ────────────────────────────
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

      # ── ci_exhausted issue recovery ────────────────────────────────
      log "Scanning for ci_exhausted issues updated in last 30 minutes..."
      _now_epoch=$(date +%s)
      _thirty_min_ago=$(( _now_epoch - 1800 ))

      # Fetch open issues with blocked label
      _blocked_issues=$(forge_api GET "/issues?state=open&labels=blocked&type=issues&limit=100" 2>/dev/null || echo "[]")
      _blocked_count=$(echo "$_blocked_issues" | jq 'length' 2>/dev/null || echo "0")

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
            log "Processing ci_exhausted issue #$_issue_num (updated $_time_since_update seconds ago)"

            # Check for idempotency guard - already swept by supervisor?
            _issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
            if echo "$_issue_body" | grep -q "<!-- supervisor-swept -->"; then
              log "Issue #$_issue_num already swept by supervisor, skipping"
              continue
            fi

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
