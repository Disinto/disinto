#!/usr/bin/env bash
# supervisor/actions/close-stuck-pr.sh — Close PRs stuck on ci_exhausted issues
#
# Implements #452 pattern: closes PRs whose linked issue has the
# blocked: ci_exhausted label and the PR has been open >2h.
#
# Sources: lib/issue-lifecycle.sh (issue_close helper), lib/ci-helpers.sh
# (forge_api via env.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shared setup (header, env, log function)
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh" "$@"
# shellcheck source=_ops-setup.sh
source "$SCRIPT_DIR/_ops-setup.sh"

# shellcheck disable=SC2034
LOG_FILE="${DISINTO_LOG_DIR}/supervisor/supervisor.log"
# shellcheck disable=SC2034
LOG_AGENT="supervisor"

log "Scanning for stuck PRs (ci_exhausted + open >2h)..."

_now_epoch=$(date +%s)
_two_hours_ago=$(( _now_epoch - 7200 ))

# Fetch open PRs
_open_prs=$(forge_api GET "/pulls?state=open&limit=100" 2>/dev/null || echo "[]")
_pr_count=$(echo "$_open_prs" | jq 'length' 2>/dev/null || echo "0")

_prs_closed=0

if [ "$_pr_count" -gt 0 ]; then
  echo "$_open_prs" | jq -c '.[]' 2>/dev/null | while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue

    _pr_num=$(echo "$pr_json" | jq -r '.number // empty')
    _pr_created=$(echo "$pr_json" | jq -r '.created_at // empty')
    _pr_title=$(echo "$pr_json" | jq -r '.title // "unknown"')

    # Check if PR is older than 2 hours
    _pr_created_epoch=$(date -d "$_pr_created" +%s 2>/dev/null || echo "0")
    _pr_age=$(( _now_epoch - _pr_created_epoch ))
    if [ "$_pr_age" -lt 7200 ]; then
      continue
    fi

    # Extract linked issue number from PR body (pattern: #N or Fixes #N)
    _pr_body=$(echo "$pr_json" | jq -r '.body // ""' 2>/dev/null)
    _linked_issue=$(printf '%s' "$_pr_body" | grep -oP '#\K[0-9]+' | head -1 || echo "")
    [ -n "$_linked_issue" ] || continue

    # Check if linked issue has ci_exhausted label
    _issue_json=$(forge_api GET "/issues/${_linked_issue}" 2>/dev/null || echo "")
    [ -n "$_issue_json" ] || continue

    _issue_state=$(echo "$_issue_json" | jq -r '.state // ""' 2>/dev/null)
    [ "$_issue_state" = "open" ] || continue

    _issue_labels=$(echo "$_issue_json" | jq -r '.labels | map(.name) | join(",")' 2>/dev/null || echo "")
    if ! echo "$_issue_labels" | grep -q "ci_exhausted"; then
      continue
    fi

    log "Closing stuck PR #$_pr_num (linked issue #$_linked_issue has ci_exhausted, open ${_pr_age}s)"

    # Post comment explaining the closure
    _close_comment=$(cat <<EOF
<!-- supervisor-auto-close -->

**Auto-closed by supervisor** — $(date -u '+%Y-%m-%d %H:%M UTC')

This PR is linked to issue #$_linked_issue which has exhausted its CI retry budget
(see \`blocked: ci_exhausted\` label). The linked issue has been returned to the
pool for re-attempt.

Please reopen this PR after the linked issue is successfully re-attempted.
EOF
)

    curl -sf -X POST \
      -H "Authorization: token ${FORGE_SUPERVISOR_TOKEN:-$FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues/${_pr_num}/comments" \
      -d "$(jq -n --arg body "$_close_comment" '{body: $body}')" >/dev/null 2>&1 || true

    # Close the PR
    curl -sf -X PATCH \
      -H "Authorization: token ${FORGE_SUPERVISOR_TOKEN:-$FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/pulls/${_pr_num}" \
      -d '{"state":"closed"}' >/dev/null 2>&1 || true

    log "Closed PR #$_pr_num (stuck on ci_exhausted issue #$_linked_issue)"
    _prs_closed=$(( _prs_closed + 1 ))
  done
fi

log "Stuck PR sweep complete: closed $_prs_closed"
