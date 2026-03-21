#!/usr/bin/env bash
# =============================================================================
# collect-metrics.sh — Collect factory metrics and write JSON for the dashboard
#
# Queries Codeberg API for PR/issue stats across all managed projects,
# counts vault decisions, and checks CI pass rates. Writes a JSON snapshot
# to the live site directory so the dashboard can fetch it.
#
# Usage:
#   bash site/collect-metrics.sh
#
# Cron: 0 */6 * * * cd /home/debian/dark-factory && bash site/collect-metrics.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh" 2>/dev/null || true

LOGFILE="${FACTORY_ROOT}/site/collect-metrics.log"
log() {
  printf '[%s] collect-metrics: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# Output path: write to live site root if deployed, else to site/data/
SITE_ROOT="${DISINTO_SITE_ROOT:-/home/debian/disinto-site}"
if [ -d "$SITE_ROOT" ] || [ -L "$SITE_ROOT" ]; then
  OUTPUT_DIR="$(readlink -f "$SITE_ROOT")/data"
else
  OUTPUT_DIR="${SCRIPT_DIR}/data"
fi
mkdir -p "$OUTPUT_DIR"

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WEEK_AGO=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
MONTH_AGO=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

# ── Per-project metrics ─────────────────────────────────────────────────────

collect_project_metrics() {
  local project_toml="$1"
  local repo repo_name

  repo=$(grep '^repo ' "$project_toml" | head -1 | sed 's/.*= *"//;s/"//')
  repo_name=$(grep '^name ' "$project_toml" | head -1 | sed 's/.*= *"//;s/"//')
  local api_base="https://codeberg.org/api/v1/repos/${repo}"

  # PRs merged (all time via state=closed + merged marker)
  local prs_merged_week=0 prs_merged_month=0 prs_merged_total=0
  local closed_prs
  closed_prs=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${api_base}/pulls?state=closed&sort=updated&limit=50" 2>/dev/null || echo "[]")

  prs_merged_total=$(printf '%s' "$closed_prs" | jq '[.[] | select(.merged)] | length' 2>/dev/null || echo 0)

  if [ -n "$WEEK_AGO" ]; then
    prs_merged_week=$(printf '%s' "$closed_prs" | \
      jq --arg since "$WEEK_AGO" '[.[] | select(.merged and .merged_at >= $since)] | length' 2>/dev/null || echo 0)
  fi
  if [ -n "$MONTH_AGO" ]; then
    prs_merged_month=$(printf '%s' "$closed_prs" | \
      jq --arg since "$MONTH_AGO" '[.[] | select(.merged and .merged_at >= $since)] | length' 2>/dev/null || echo 0)
  fi

  # Issues closed
  local issues_closed_week=0 issues_closed_month=0
  local closed_issues
  closed_issues=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${api_base}/issues?state=closed&sort=updated&type=issues&limit=50" 2>/dev/null || echo "[]")

  if [ -n "$WEEK_AGO" ]; then
    issues_closed_week=$(printf '%s' "$closed_issues" | \
      jq --arg since "$WEEK_AGO" '[.[] | select(.closed_at >= $since)] | length' 2>/dev/null || echo 0)
  fi
  if [ -n "$MONTH_AGO" ]; then
    issues_closed_month=$(printf '%s' "$closed_issues" | \
      jq --arg since "$MONTH_AGO" '[.[] | select(.closed_at >= $since)] | length' 2>/dev/null || echo 0)
  fi

  local total_closed_header
  total_closed_header=$(curl -sf -I -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${api_base}/issues?state=closed&type=issues&limit=1" 2>/dev/null | grep -i 'x-total-count' | tr -d '\r' | awk '{print $2}' || echo "0")
  local issues_closed_total="${total_closed_header:-0}"

  # Open issues by label
  local backlog_count in_progress_count blocked_count
  backlog_count=$(curl -sf -I -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${api_base}/issues?state=open&labels=backlog&type=issues&limit=1" 2>/dev/null | \
    grep -i 'x-total-count' | tr -d '\r' | awk '{print $2}' || echo "0")
  in_progress_count=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${api_base}/issues?state=open&labels=in-progress&type=issues&limit=50" 2>/dev/null | \
    jq 'length' 2>/dev/null || echo 0)
  blocked_count=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${api_base}/issues?state=open&labels=blocked&type=issues&limit=50" 2>/dev/null | \
    jq 'length' 2>/dev/null || echo 0)

  jq -nc \
    --arg name "$repo_name" \
    --arg repo "$repo" \
    --argjson prs_week "$prs_merged_week" \
    --argjson prs_month "$prs_merged_month" \
    --argjson prs_total "${prs_merged_total:-0}" \
    --argjson issues_week "$issues_closed_week" \
    --argjson issues_month "$issues_closed_month" \
    --argjson issues_total "${issues_closed_total:-0}" \
    --argjson backlog "${backlog_count:-0}" \
    --argjson in_progress "${in_progress_count:-0}" \
    --argjson blocked "${blocked_count:-0}" \
    '{
      name: $name,
      repo: $repo,
      prs_merged: { week: $prs_week, month: $prs_month, total: $prs_total },
      issues_closed: { week: $issues_week, month: $issues_month, total: $issues_total },
      backlog: { queued: $backlog, in_progress: $in_progress, blocked: $blocked }
    }'
}

# ── Vault decisions ─────────────────────────────────────────────────────────

collect_vault_metrics() {
  local vault_dir="${FACTORY_ROOT}/vault"
  local approved=0 rejected=0 escalated=0 pending=0 fired=0

  [ -d "$vault_dir/fired" ] && fired=$(find "$vault_dir/fired" -name '*.json' 2>/dev/null | wc -l)
  [ -d "$vault_dir/approved" ] && approved=$(find "$vault_dir/approved" -name '*.json' 2>/dev/null | wc -l)
  [ -d "$vault_dir/rejected" ] && rejected=$(find "$vault_dir/rejected" -name '*.json' 2>/dev/null | wc -l)
  [ -d "$vault_dir/pending" ] && {
    pending=$(find "$vault_dir/pending" -name '*.json' 2>/dev/null | wc -l)
    escalated=$(find "$vault_dir/pending" -name '*.json' -exec grep -l '"escalated"' {} + 2>/dev/null | wc -l)
    pending=$((pending - escalated))
  }

  jq -nc \
    --argjson approved "$((approved + fired))" \
    --argjson escalated "$escalated" \
    --argjson rejected "$rejected" \
    --argjson pending "$pending" \
    '{ approved: $approved, escalated: $escalated, rejected: $rejected, pending: $pending }'
}

# ── CI pass rate ────────────────────────────────────────────────────────────

collect_ci_metrics() {
  local total=0 passed=0 failed=0 rate=0

  # Query Woodpecker DB for last 30 days across all repos
  local ci_stats
  ci_stats=$(wpdb -A -c "
    SELECT status, count(*)
    FROM pipelines
    WHERE finished > 0
      AND to_timestamp(finished) > now() - interval '30 days'
    GROUP BY status;" 2>/dev/null || echo "")

  if [ -n "$ci_stats" ]; then
    passed=$(echo "$ci_stats" | awk '$1 == "success" {print $3}' | tr -d ' ' || echo 0)
    failed=$(echo "$ci_stats" | awk '$1 == "failure" {print $3}' | tr -d ' ' || echo 0)
    passed=${passed:-0}
    failed=${failed:-0}
    total=$((passed + failed))
    if [ "$total" -gt 0 ]; then
      rate=$(( (passed * 100) / total ))
    fi
  fi

  jq -nc \
    --argjson total "$total" \
    --argjson passed "$passed" \
    --argjson failed "$failed" \
    --argjson rate "$rate" \
    '{ total: $total, passed: $passed, failed: $failed, pass_rate: $rate }'
}

# ── Agent activity ──────────────────────────────────────────────────────────

collect_agent_metrics() {
  local active_sessions=0
  active_sessions=$(tmux list-sessions 2>/dev/null | wc -l || echo 0)

  local agents='[]'
  local agent_name log_path age_min last_active
  for log_entry in dev/dev-agent.log review/review.log gardener/gardener.log \
                   planner/planner.log predictor/predictor.log supervisor/supervisor.log \
                   action/action.log vault/vault.log; do
    agent_name=$(basename "$(dirname "$log_entry")")
    log_path="${FACTORY_ROOT}/${log_entry}"
    if [ -f "$log_path" ]; then
      age_min=$(( ($(date +%s) - $(stat -c %Y "$log_path" 2>/dev/null || echo 0)) / 60 ))
      last_active=$(date -u -d "@$(stat -c %Y "$log_path" 2>/dev/null || echo 0)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
      agents=$(printf '%s' "$agents" | jq --arg n "$agent_name" --arg t "$last_active" --argjson a "$age_min" \
        '. + [{ name: $n, last_active: $t, idle_minutes: $a }]')
    fi
  done

  jq -nc --argjson sessions "$active_sessions" --argjson agents "$agents" \
    '{ active_sessions: $sessions, agents: $agents }'
}

# ── Assemble ────────────────────────────────────────────────────────────────

log "Starting metrics collection"

PROJECTS_JSON="[]"
for toml in "$FACTORY_ROOT"/projects/*.toml; do
  [ -f "$toml" ] || continue
  log "Collecting metrics for $(basename "$toml")"
  project_json=$(collect_project_metrics "$toml" 2>/dev/null || echo '{}')
  PROJECTS_JSON=$(printf '%s\n%s' "$PROJECTS_JSON" "$project_json" | jq -s '.[0] + [.[1]]')
done

VAULT_JSON=$(collect_vault_metrics 2>/dev/null || echo '{}')
CI_JSON=$(collect_ci_metrics 2>/dev/null || echo '{}')
AGENTS_JSON=$(collect_agent_metrics 2>/dev/null || echo '{}')

# Build final output
jq -nc \
  --arg ts "$NOW_ISO" \
  --argjson projects "$PROJECTS_JSON" \
  --argjson vault "$VAULT_JSON" \
  --argjson ci "$CI_JSON" \
  --argjson agents "$AGENTS_JSON" \
  '{
    generated_at: $ts,
    projects: $projects,
    vault: $vault,
    ci: $ci,
    agents: $agents
  }' > "${OUTPUT_DIR}/metrics.json"

log "Metrics written to ${OUTPUT_DIR}/metrics.json"
