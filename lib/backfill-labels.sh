#!/usr/bin/env bash
# =============================================================================
# backfill-labels.sh — Backfill labels on issues that were filed out of band
#
# Usage:
#   backfill-labels.sh <issue-num> <label> [<label> ...]
#   backfill-labels.sh 1105 backlog
#   backfill-labels.sh 1105 1106 1107 backlog
#
# Environment:
#   FORGE_TOKEN     — API token with issues:write scope (used for label operations)
#   FORGE_API       — project repo API base URL
#
# This script is a one-off tool for recovering from out-of-band issue filing
# (e.g., architect-bot filing sub-issues directly instead of through filer-bot).
# See issue #1140 for context.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${FACTORY_ROOT:-}" ]; then
  FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"
  # shellcheck source=lib/env.sh
  source "$FACTORY_ROOT/lib/env.sh"
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <issue-num> [<issue-num> ...] <label> [<label> ...]" >&2
  echo "  Last positional arg(s) are labels. All preceding args are issue numbers." >&2
  exit 1
fi

# Split args: last N unique non-numeric args are labels, rest are issue numbers
args=("$@")
issue_nums=()
labels=()

for arg in "${args[@]}"; do
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    issue_nums+=("$arg")
  else
    # Check if it looks like a label (not a number)
    labels+=("$arg")
  fi
done

# If we have no non-numeric labels, treat the last arg as a label
if [ ${#labels[@]} -eq 0 ] && [ $# -gt 0 ]; then
  labels=("${args[-1]}")
  # Rebuild issue_nums from all non-label args
  for arg in "${args[@]:0:$(($# - 1))}"; do
    issue_nums+=("$arg")
  done
fi

if [ ${#issue_nums[@]} -eq 0 ]; then
  echo "ERROR: no issue numbers specified" >&2
  exit 1
fi

if [ ${#labels[@]} -eq 0 ]; then
  echo "ERROR: no labels specified" >&2
  exit 1
fi

# Resolve label IDs
label_ids_json="[]"
for label_name in "${labels[@]}"; do
  label_id=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/labels" 2>/dev/null | jq -r --arg name "$label_name" \
    '.[] | select(.name == $name) | .id' 2>/dev/null) || true
  if [ -n "$label_id" ]; then
    label_ids_json=$(printf '%s' "$label_ids_json" | jq --argjson id "$label_id" '. + [$id]')
  else
    echo "WARNING: label '${label_name}' not found on project repo" >&2
  fi
done

if [ "$(printf '%s' "$label_ids_json" | jq 'length')" -eq 0 ]; then
  echo "ERROR: no label IDs resolved — cannot proceed" >&2
  exit 1
fi

# Apply labels to each issue
for issue_num in "${issue_nums[@]}"; do
  echo "Adding labels ${labels[*]} to issue #${issue_num}..."
  if ! curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue_num}/labels" \
    -d "{\"labels\": $(printf '%s' "$label_ids_json")}" 2>/dev/null; then
    echo "ERROR: failed to add labels to issue #${issue_num}" >&2
    continue
  fi
  echo "  OK — issue #${issue_num} updated"
done

echo "Done."
