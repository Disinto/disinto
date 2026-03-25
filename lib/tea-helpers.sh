#!/usr/bin/env bash
# tea-helpers.sh — Thin wrappers around tea CLI for forge issue operations
#
# Usage: source this file (after env.sh), then call tea_* functions.
# Requires: tea binary in PATH, TEA_LOGIN and FORGE_REPO from env.sh,
#           scan_for_secrets from lib/secret-scan.sh
#
# tea_file_issue <title> <body> <labels...>
#   Sets FILED_ISSUE_NUM on success.
#   Returns: 0=created, 3=API/tea error, 4=secrets detected
#
# tea_relabel  <issue_number> <labels...>
# tea_comment  <issue_number> <body>
# tea_close    <issue_number>

# Load secret scanner
# shellcheck source=secret-scan.sh
source "$(dirname "${BASH_SOURCE[0]}")/secret-scan.sh"

tea_file_issue() {
  local title="$1" body="$2"
  shift 2
  FILED_ISSUE_NUM=""

  # Secret scan: reject issue bodies containing embedded secrets
  if ! scan_for_secrets "$body"; then
    echo "tea-helpers: BLOCKED — issue body contains potential secrets. Use env var references instead." >&2
    return 4
  fi

  # Join remaining args as comma-separated label names
  local IFS=','
  local labels="$*"

  local result
  result=$(tea issues create --login "$TEA_LOGIN" --repo "$FORGE_REPO" \
    --title "$title" --body "$body" --labels "$labels" \
    --output simple 2>&1) || {
    echo "tea-helpers: tea issues create failed: ${result}" >&2
    return 3
  }

  # Parse issue number from tea output (e.g. "#42 Title")
  FILED_ISSUE_NUM=$(printf '%s' "$result" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
  if [ -z "$FILED_ISSUE_NUM" ]; then
    # Fallback: extract any number
    FILED_ISSUE_NUM=$(printf '%s' "$result" | grep -oE '[0-9]+' | head -1)
  fi
}

tea_relabel() {
  local issue_num="$1"
  shift

  local IFS=','
  local labels="$*"

  tea issues labels "$issue_num" --login "$TEA_LOGIN" --repo "$FORGE_REPO" \
    --labels "$labels"
}

tea_comment() {
  local issue_num="$1" body="$2"

  # Secret scan: reject comment bodies containing embedded secrets
  if ! scan_for_secrets "$body"; then
    echo "tea-helpers: BLOCKED — comment body contains potential secrets. Use env var references instead." >&2
    return 4
  fi

  tea comment create "$issue_num" --login "$TEA_LOGIN" --repo "$FORGE_REPO" \
    --body "$body"
}

tea_close() {
  local issue_num="$1"
  tea issues close "$issue_num" --login "$TEA_LOGIN" --repo "$FORGE_REPO"
}
