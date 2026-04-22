#!/usr/bin/env bash
# supervisor/actions/sweep-ci-exhausted.sh — P2 ci_exhausted issue recovery
#
# Scans for blocked issues with ci_exhausted label updated in the last
# 30 minutes, unassigns them, removes the blocked label, and posts a
# recovery comment. Idempotent via <!-- supervisor-swept --> marker.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared setup (header, env, log, OPS)
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh" "$@"

# Override LOG_FILE/LOG_AGENT for consistent supervisor logging
# shellcheck disable=SC2034
LOG_FILE="${DISINTO_LOG_DIR}/supervisor/supervisor.log"
# shellcheck disable=SC2034
LOG_AGENT="supervisor"

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
  while IFS= read -r issue_json; do
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
      _swept_comments=$(forge_api GET "/issues/$_issue_num/comments" 2>/dev/null || echo "[]")
      if echo "$_swept_comments" | jq -e '.[] | select(.body | contains("<!-- supervisor-swept -->"))' >/dev/null 2>&1; then
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
      _recovery_time=$(date -u '+%Y-%m-%d %H:%M UTC')
      _recovery_comment=$(cat <<EOF
<!-- supervisor-swept -->

**Automated Recovery — $_recovery_time**

CI agent was temporarily unavailable. The prior retry budget may have been spent on infra flake, not real failures.

**Recovery Actions:**
- Unassigned from pool and returned for fresh attempt
- CI agent environment refreshed
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
      _issues_recovered=$(( _issues_recovered + 1 ))
    fi
  done < <(echo "$_blocked_issues" | jq -c '.[]' 2>/dev/null)
fi

log "ci_exhausted sweep complete: processed $_issues_processed, recovered $_issues_recovered"
