#!/usr/bin/env bash
# file-action-issue.sh — File an action issue for a formula run
#
# Usage: source this file, then call file_action_issue.
# Requires: codeberg_api() from lib/env.sh, jq, lib/secret-scan.sh
#
# file_action_issue <formula_name> <title> <body>
#   Sets FILED_ISSUE_NUM on success.
#   Returns: 0=created, 1=duplicate exists, 2=label not found, 3=API error, 4=secrets detected

# Load secret scanner
# shellcheck source=secret-scan.sh
source "$(dirname "${BASH_SOURCE[0]}")/secret-scan.sh"

file_action_issue() {
  local formula_name="$1" title="$2" body="$3"
  FILED_ISSUE_NUM=""

  # Secret scan: reject issue bodies containing embedded secrets
  if ! scan_for_secrets "$body"; then
    echo "file-action-issue: BLOCKED — issue body for '${formula_name}' contains potential secrets. Use env var references instead." >&2
    return 4
  fi

  # Dedup: skip if an open action issue for this formula already exists
  local open_actions
  open_actions=$(codeberg_api_all "/issues?state=open&type=issues&labels=action" 2>/dev/null || true)
  if [ -n "$open_actions" ] && [ "$open_actions" != "null" ]; then
    local existing
    existing=$(printf '%s' "$open_actions" | \
      jq --arg f "$formula_name" '[.[] | select(.title | test($f))] | length' 2>/dev/null || echo 0)
    if [ "${existing:-0}" -gt 0 ]; then
      return 1
    fi
  fi

  # Fetch 'action' label ID
  local action_label_id
  action_label_id=$(codeberg_api GET "/labels" 2>/dev/null | \
    jq -r '.[] | select(.name == "action") | .id' 2>/dev/null || true)
  if [ -z "$action_label_id" ]; then
    return 2
  fi

  # Create the issue
  local payload result
  payload=$(jq -nc \
    --arg title "$title" \
    --arg body "$body" \
    --argjson labels "[$action_label_id]" \
    '{title: $title, body: $body, labels: $labels}')

  result=$(codeberg_api POST "/issues" -d "$payload" 2>/dev/null || true)
  FILED_ISSUE_NUM=$(printf '%s' "$result" | jq -r '.number // empty' 2>/dev/null || true)

  if [ -z "$FILED_ISSUE_NUM" ]; then
    return 3
  fi
}
